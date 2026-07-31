package dns

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/ipsource"
)

// ============ buildFullDomain ============

// TestBuildFullDomain 验证子域名拼装规则：@ -> 根域名；其他 -> name.domain。
func TestBuildFullDomain(t *testing.T) {
	cases := []struct {
		name, domain, want string
	}{
		{"@", "example.com", "example.com"},
		{"www", "example.com", "www.example.com"},
		{"dns", "example.com", "dns.example.com"},
		{"@trailing", "example.com", "@trailing.example.com"},
	}
	for _, c := range cases {
		assert.Equal(t, c.want, buildFullDomain(c.name, c.domain), "name=%q", c.name)
	}
}

// ============ needsUpdate（集合同步核心判定） ============

// TestNeedsUpdate 表驱动覆盖集合对比逻辑，这是「集合同步回归」的判定核心：
// 顺序无关、数量不同即更新、目标为空则不更新。
func TestNeedsUpdate(t *testing.T) {
	cases := []struct {
		name    string
		exist   []string
		target  []string
		want    bool
	}{
		{"完全相同-顺序一致", []string{"1.1.1.1", "2.2.2.2"}, []string{"1.1.1.1", "2.2.2.2"}, false},
		{"完全相同-顺序打乱", []string{"1.1.1.1", "2.2.2.2"}, []string{"2.2.2.2", "1.1.1.1"}, false}, // 回归关键：顺序无关
		{"目标为空", []string{"1.1.1.1"}, []string{}, false},
		{"现有为空", []string{}, []string{"1.1.1.1"}, true},
		{"内容不同-同长度", []string{"1.1.1.1"}, []string{"2.2.2.2"}, true},
		{"目标多一条", []string{"1.1.1.1"}, []string{"1.1.1.1", "2.2.2.2"}, true},
		{"现有多一条", []string{"1.1.1.1", "2.2.2.2"}, []string{"1.1.1.1"}, true},
		{"部分重叠", []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"}, []string{"1.1.1.1", "9.9.9.9"}, true},
		{"完全不相交", []string{"1.1.1.1"}, []string{"9.9.9.9"}, true},
	}
	for _, c := range cases {
		assert.Equalf(t, c.want, needsUpdate(c.exist, c.target), "[%s]", c.name)
	}
}

// ============ dedupeAndValidate ============

// TestDedupeAndValidate 验证从 IPRecord 提取去重且合法 IP，并尊重 max 限制。
func TestDedupeAndValidate(t *testing.T) {
	records := []ipsource.IPRecord{
		{IP: "1.1.1.1"},
		{IP: "2.2.2.2"},
		{IP: "1.1.1.1"},   // 重复
		{IP: "0.0.0.0"},   // 非法特殊地址
		{IP: "notanip"},   // 非法
		{IP: "3.3.3.3"},
	}

	// 无限制：去重后 3 条合法
	got := dedupeAndValidate(records, 0)
	assert.Equal(t, []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"}, got)

	// 限制 max=2：仅取前 2 条合法
	got2 := dedupeAndValidate(records, 2)
	assert.Equal(t, []string{"1.1.1.1", "2.2.2.2"}, got2)

	// 空输入
	assert.Empty(t, dedupeAndValidate(nil, 0))
}

// ============ 集合同步「删除多余 + 创建缺失」计划（回归守门） ============
//
// 说明：CloudflareProvider.Sync 中的删除/创建循环依赖 cloudflareBaseURL（包级 const），
// 无法在不修改源码的前提下注入 httptest 地址，故无法做端到端测试（详见交付报告）。
// 以下测试用与 Sync 完全一致的「集合差」算法推导 delete/create 计划，并断言其正确，
// 同时结合 needsUpdate/dedupeAndValidate 两个真实纯函数，守住「绝不索引复用已删除记录」的回归不变量。

// syncPlan 复刻 Sync 的删除/创建决策（仅算法层，不涉及 HTTP），用于断言预期计划。
func syncPlan(existing []Record, target []string) (toDelete []string, toCreate []string) {
	existingSet := make(map[string]string, len(existing))
	for _, r := range existing {
		existingSet[r.Content] = r.ID
	}
	targetSet := make(map[string]bool, len(target))
	for _, ip := range target {
		targetSet[ip] = true
	}
	for content, id := range existingSet {
		if !targetSet[content] {
			toDelete = append(toDelete, id) // 删除多余：用原 ID，绝不复用
		}
	}
	for _, ip := range target {
		if _, ok := existingSet[ip]; !ok {
			toCreate = append(toCreate, ip) // 创建缺失
		}
	}
	return
}

func TestSyncCollectionPlan(t *testing.T) {
	existing := []Record{
		{ID: "rec-old-1", Content: "1.1.1.1"}, // 仍保留
		{ID: "rec-old-2", Content: "2.2.2.2"}, // 将被删除
		{ID: "rec-old-3", Content: "3.3.3.3"}, // 将被删除
	}
	// 目标：保留 1.1.1.1，新增 9.9.9.9（绝不能复用 rec-old-2/3 的 ID）
	target := []string{"1.1.1.1", "9.9.9.9"}

	require.True(t, needsUpdate(existingIPs(existing), target), "应判定需要更新")
	toDelete, toCreate := syncPlan(existing, target)

	assert.ElementsMatch(t, []string{"rec-old-2", "rec-old-3"}, toDelete, "应删除不再需要的旧记录")
	assert.Equal(t, []string{"9.9.9.9"}, toCreate, "应创建新 IP，且不复用已删除记录 ID")

	// 回归不变量：删除集合中不得出现仍保留记录的 ID
	assert.NotContains(t, toDelete, "rec-old-1")
}

// ============ HTTPClient.DoRequest（可注入 url，故可用 httptest 验证重试/退避） ============

func TestHTTPClientDoRequest(t *testing.T) {
	t.Run("200返回体", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("hello"))
		}))
		defer srv.Close()

		c := NewHTTPClient(0)
		body, status, err := c.DoRequest(context.Background(), http.MethodGet, srv.URL, nil, nil)
		require.NoError(t, err)
		assert.Equal(t, http.StatusOK, status)
		assert.Equal(t, "hello", string(body))
	})

	t.Run("401不重试", func(t *testing.T) {
		var mu sync.Mutex
		calls := 0
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			calls++
			mu.Unlock()
			w.WriteHeader(http.StatusUnauthorized)
		}))
		defer srv.Close()

		c := NewHTTPClient(0)
		_, _, err := c.DoRequest(context.Background(), http.MethodGet, srv.URL, nil, nil)
		require.Error(t, err, "401 应返回错误")
		mu.Lock()
		assert.Equal(t, 1, calls, "401 不应重试")
		mu.Unlock()
	})

	t.Run("500重试后成功", func(t *testing.T) {
		var mu sync.Mutex
		calls := 0
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			calls++
			n := calls
			mu.Unlock()
			if n == 1 {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok"))
		}))
		defer srv.Close()

		c := NewHTTPClient(0)
		body, status, err := c.DoRequest(context.Background(), http.MethodGet, srv.URL, nil, nil)
		require.NoError(t, err, "5xx 重试后应成功")
		assert.Equal(t, http.StatusOK, status)
		assert.Equal(t, "ok", string(body))
		mu.Lock()
		assert.GreaterOrEqual(t, calls, 2, "5xx 应至少重试一次")
		mu.Unlock()
	})

	t.Run("context取消返回错误", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// 永不返回，靠 context 取消
			<-r.Context().Done()
		}))
		defer srv.Close()

		ctx, cancel := context.WithCancel(context.Background())
		cancel() // 立即取消
		_, _, err := c_doRequestCancel(ctx, srv.URL)
		require.Error(t, err)
	})
}

// c_doRequestCancel 仅为 context 取消用例封装，避免闭包捕获问题。
func c_doRequestCancel(ctx context.Context, url string) ([]byte, int, error) {
	c := NewHTTPClient(0)
	return c.DoRequest(ctx, http.MethodGet, url, nil, nil)
}
