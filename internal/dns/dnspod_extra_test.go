package dns

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// ---------------------------------------------------------------------------
// P0-1：无数据错误码（记录不存在）应被识别为「空列表」而非失败
// ---------------------------------------------------------------------------

func TestDNSPodListRecords_NoDataReturnsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{
				"Error": map[string]any{"Code": "ResourceNotFound.NoDataOfRecord", "Message": "no data of record"},
			},
		})
	}))
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	p := NewDNSPodProvider(&config.DNSPodConfig{SecretID: "id", SecretKey: "key", Domain: "example.com"})
	recs, err := p.listRecords(context.Background(), "example.com", "www", "默认")
	require.NoError(t, err, "无数据错误码应视为空列表，不应返回错误")
	assert.Empty(t, recs)
}

func TestIsNoDataError_DetectsAllCodes(t *testing.T) {
	for code := range noDataCodes {
		err := &dnspodNoDataError{code: code, msg: "x"}
		assert.True(t, IsNoDataError(err), "应识别无数据错误码: %s", code)
	}
	assert.False(t, IsNoDataError(fmt.Errorf("other error")), "普通错误不应被误判")
}

// ---------------------------------------------------------------------------
// P1-2：TTL 默认 600
// ---------------------------------------------------------------------------

func TestNewDNSPodProvider_TTLDefault(t *testing.T) {
	p0 := NewDNSPodProvider(&config.DNSPodConfig{TTL: 0})
	assert.Equal(t, 600, p0.ttl, "TTL<=0 应回退到默认 600")

	p1 := NewDNSPodProvider(&config.DNSPodConfig{TTL: 300})
	assert.Equal(t, 300, p1.ttl, "配置了 TTL 应直接使用")
}

// ---------------------------------------------------------------------------
// LineAwareProvider 实现（Upsert/List/Delete）端到端
// 用带状态的内存 httptest server 充当 DNSPod API。
// ---------------------------------------------------------------------------

// dnspodLineServer 维护 per sub|line 的内存记录，响应 Describe/Create/Modify/Delete，
// 并统计各类写操作次数（Create/Modify/Delete）以便断言分支执行。
type dnspodLineServer struct {
	srv     *httptest.Server
	mu      sync.Mutex
	creates int
	modifies int
	deletes int
}

func (s *dnspodLineServer) Creates() int  { s.mu.Lock(); defer s.mu.Unlock(); return s.creates }
func (s *dnspodLineServer) Modifies() int { s.mu.Lock(); defer s.mu.Unlock(); return s.modifies }
func (s *dnspodLineServer) Deletes() int  { s.mu.Lock(); defer s.mu.Unlock(); return s.deletes }

func newDNSPodLineServer(t *testing.T) *dnspodLineServer {
	t.Helper()
	st := &dnspodLineServer{}
	state := map[string][]map[string]any{} // key sub|line -> records
	key := func(sub, line string) string { return sub + "|" + line }

	st.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		action := r.Header.Get("X-TC-Action")
		sub := toString(payload["SubDomain"])
		line := toString(payload["RecordLine"])
		k := key(sub, line)

		st.mu.Lock()
		defer st.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")

		switch action {
		case "DescribeRecordList":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"RecordList": state[k], "RequestId": "x"},
			})
		case "CreateRecord":
			st.creates++
			v := toString(payload["Value"])
			ttl := toInt(payload["TTL"])
			id := len(state[k]) + 1
			state[k] = append(state[k], map[string]any{"RecordId": id, "Value": v, "Line": line, "TTL": ttl})
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"RecordId": id, "RequestId": "x"},
			})
		case "ModifyRecord":
			st.modifies++
			id := toInt(payload["RecordId"])
			ttl := toInt(payload["TTL"])
			for _, rec := range state[k] {
				if rec["RecordId"] == id {
					rec["TTL"] = ttl
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"RecordId": id, "RequestId": "x"},
			})
		case "DeleteRecord":
			st.deletes++
			// DeleteRecord 仅带 Domain/RecordId（无 sub/line），按 RecordId 在所有线路中查找删除。
			id := toInt(payload["RecordId"])
			for kk, recs := range state {
				out := make([]map[string]any, 0, len(recs))
				for _, rec := range recs {
					if rec["RecordId"] != id {
						out = append(out, rec)
					}
				}
				state[kk] = out
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"RequestId": "x"},
			})
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"Response": map[string]any{"RequestId": "x"}})
		}
	}))
	t.Cleanup(st.srv.Close)
	return st
}

func TestDNSPodProvider_LineAware(t *testing.T) {
	srv := newDNSPodLineServer(t)
	orig := dnspodBaseURL
	dnspodBaseURL = srv.srv.URL
	defer func() { dnspodBaseURL = orig }()

	p := NewDNSPodProvider(&config.DNSPodConfig{SecretID: "id", SecretKey: "key", Domain: "example.com", SubDomain: "www"})
	ctx := context.Background()

	// 创建：应触发一次 CreateRecord。
	require.NoError(t, p.UpsertLineRecord(ctx, "example.com", "www", "默认", "1.1.1.1", 600))
	require.Equal(t, 1, srv.Creates(), "应触发一次 CreateRecord")
	recs, err := p.ListLineRecords(ctx, "example.com", "www", "默认")
	require.NoError(t, err)
	require.Len(t, recs, 1)
	assert.Equal(t, "1.1.1.1", recs[0].Content)

	// 相同 value、不同 TTL → 应走 modify，不新建第二条（创建数保持 1）。
	require.NoError(t, p.UpsertLineRecord(ctx, "example.com", "www", "默认", "1.1.1.1", 300))
	require.Equal(t, 1, srv.Creates(), "相同 value 不应重复创建")
	require.GreaterOrEqual(t, srv.Modifies(), 1, "TTL 变化应触发 ModifyRecord")
	recs, _ = p.ListLineRecords(ctx, "example.com", "www", "默认")
	require.Len(t, recs, 1, "记录数应保持 1（修改而非新增）")

	// 不同 value → 应新建第二条。
	require.NoError(t, p.UpsertLineRecord(ctx, "example.com", "www", "默认", "2.2.2.2", 300))
	require.Equal(t, 2, srv.Creates(), "新 value 应触发第二次 CreateRecord")
	recs, _ = p.ListLineRecords(ctx, "example.com", "www", "默认")
	require.Len(t, recs, 2)

	// 删除：应触发一次 DeleteRecord，记录清空。
	require.NoError(t, p.DeleteLineRecord(ctx, "example.com", recs[0].ID))
	require.Equal(t, 1, srv.Deletes())
	recs, _ = p.ListLineRecords(ctx, "example.com", "www", "默认")
	assert.Len(t, recs, 1, "删除一条后应剩余一条")
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

func toString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", x)
	}
}

func toInt(v any) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	default:
		return 0
	}
}
