package dns

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/ipsource"
)

// ============ existingIPs ============

// TestExistingIPs 验证从 Record 列表提取 Content 切片。
func TestExistingIPs(t *testing.T) {
	recs := []Record{
		{ID: "a", Content: "1.1.1.1", Line: "默认"},
		{ID: "b", Content: "2.2.2.2", Line: "联通"},
	}
	assert.Equal(t, []string{"1.1.1.1", "2.2.2.2"}, existingIPs(recs))
	assert.Empty(t, existingIPs(nil))
}

// ============ subDomainForLine ============

// TestSubDomainForLine 验证线路 -> 子域名映射：优先 sub_domains，回退 sub_domain，再回退线路小写。
func TestSubDomainForLine(t *testing.T) {
	p := &DNSPodProvider{
		subDomain: "www",
		subDomains: map[string]string{
			"联通": "unicom",
			"移动": "mobile",
		},
	}

	assert.Equal(t, "unicom", p.subDomainForLine("联通"), "命中 sub_domains")
	assert.Equal(t, "mobile", p.subDomainForLine("移动"), "命中 sub_domains")
	// "默认" 不在 sub_domains -> 回退到 subDomain
	assert.Equal(t, "www", p.subDomainForLine("默认"))
	// 未知线路且无 subDomain 时回退线路小写（此处有 subDomain，故仍回退到 www）
	assert.Equal(t, "www", p.subDomainForLine("电信"))

	// 无 subDomain 也无 subDomains：回退线路小写（ASCII 线路名演示 ToLower 回退）
	p2 := &DNSPodProvider{}
	assert.Equal(t, "telecom", p2.subDomainForLine("Telecom"))
}

// ============ DNSPod 集合同步计划（多线路回归守门） ============
//
// 与 Cloudflare 同理，DNSPodProvider.Sync/syncLine 的删除+创建循环依赖 dnspodBaseURL（包级 const），
// 无法注入 httptest，故端到端不可测。此处用与 syncLine 一致的集合差算法 + 真实纯函数
// needsUpdate/existingIPs/dedupeAndValidate 守住「绝不索引复用已删除记录」的回归不变量。

// TestDNSPodSyncCollectionPlan 验证多线路场景下的删除/创建计划正确。
func TestDNSPodSyncCollectionPlan(t *testing.T) {
	existing := []Record{
		{ID: "r1", Content: "1.1.1.1", Line: "默认"}, // 保留
		{ID: "r2", Content: "2.2.2.2", Line: "默认"}, // 删除
	}
	target := []string{"1.1.1.1", "8.8.8.8"} // 保留 1.1.1.1，新增 8.8.8.8

	require.True(t, needsUpdate(existingIPs(existing), target))
	toDelete, toCreate := syncPlan(existing, target)

	assert.ElementsMatch(t, []string{"r2"}, toDelete, "应删除不再需要的旧记录 r2")
	assert.Equal(t, []string{"8.8.8.8"}, toCreate, "应创建新 IP，不复用 r2 的 ID")
	assert.NotContains(t, toDelete, "r1")
}

// TestDedupeAndValidateViaDNSPod 复用共享纯函数，验证 DNSPod 路径去重校验一致。
func TestDedupeAndValidateViaDNSPod(t *testing.T) {
	in := []ipsource.IPRecord{
		{IP: "1.1.1.1"},
		{IP: "1.1.1.1"},          // 重复
		{IP: "255.255.255.255"},  // 非法
	}
	got := dedupeAndValidate(in, 0)
	assert.Equal(t, []string{"1.1.1.1"}, got)
}
