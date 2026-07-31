package dns

import (
	"context"

	"cfopt/internal/common"
	"cfopt/internal/ipsource"
)

// DNSProvider DNS 提供方统一接口（Cloudflare 与 DNSPod 共用）。
type DNSProvider interface {
	ListRecords(ctx context.Context, domain string) ([]Record, error)
	UpsertRecord(ctx context.Context, domain string, rec Record) error
	DeleteRecord(ctx context.Context, domain string, id string) error
}

// needsUpdate 集合对比：目标 IP 集合与现有 IP 集合是否不同（需要更新）。
// 任意一方为空、数量不同、或出现新 IP 均视为需要更新。
func needsUpdate(existing []string, target []string) bool {
	if len(target) == 0 {
		return false
	}
	if len(existing) == 0 {
		return true
	}
	if len(existing) != len(target) {
		return true
	}
	set := make(map[string]struct{}, len(existing))
	for _, ip := range existing {
		set[ip] = struct{}{}
	}
	for _, ip := range target {
		if _, ok := set[ip]; !ok {
			return true
		}
	}
	return false
}

// dedupeAndValidate 从 IPRecord 列表提取去重且合法的 IP，最多 max 个（max<=0 不限制）。
func dedupeAndValidate(records []ipsource.IPRecord, max int) []string {
	seen := make(map[string]struct{})
	out := make([]string, 0, len(records))
	for _, r := range records {
		if err := common.ValidateIP(r.IP); err != nil {
			continue
		}
		if _, ok := seen[r.IP]; ok {
			continue
		}
		seen[r.IP] = struct{}{}
		out = append(out, r.IP)
		if max > 0 && len(out) >= max {
			break
		}
	}
	return out
}

// 编译期接口实现断言。
var (
	_ DNSProvider = (*CloudflareProvider)(nil)
	_ DNSProvider = (*DNSPodProvider)(nil)
)
