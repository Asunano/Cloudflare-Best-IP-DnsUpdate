// Package dns 实现 DNS 提供方抽象与 Cloudflare / DNSPod 具体实现。
// Cloudflare 与 DNSPod 复用同一套 Record 类型、共享 HTTP 客户端(common/http.go)
// 与 common.ValidateIP / common 日志，避免重复实现传输层与 IP 校验逻辑。
package dns

// RecordType 是 DNS 记录类型常量。
const (
	RecordTypeA     = "A"
	RecordTypeAAAA  = "AAAA"
	RecordTypeCNAME = "CNAME"
)

// Record 表示一条 DNS 记录（Cloudflare 与 DNSPod 共用）。
type Record struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Type    string `json:"type"`
	Content string `json:"content"`
	TTL     int    `json:"ttl"`
	Proxied bool   `json:"proxied"`
	Line    string `json:"line,omitempty"` // DNSPod 线路（如 默认/联通），Cloudflare 忽略
}

// SyncResult 一次同步的统计结果。
// Updated：就地更新数；Created：新建数；Deleted：删除数；Errors：各线路/步骤的错误摘要；
// Warnings：非阻断告警（如 IP 源文件过期 / IP 数量剧变），供 CLI/GUI 展示。
type SyncResult struct {
	Updated  int      `json:"updated"`
	Created  int      `json:"created"`
	Deleted  int      `json:"deleted"`
	Errors   []string `json:"errors,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

// cloudflareListResp Cloudflare DNS 记录列表响应。
type cloudflareListResp struct {
	Success bool `json:"success"`
	Errors  []struct {
		Message string `json:"message"`
	} `json:"errors"`
	Result []struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Type    string `json:"type"`
		Content string `json:"content"`
		TTL     int    `json:"ttl"`
		Proxied bool   `json:"proxied"`
	} `json:"result"`
}

// cloudflareResp Cloudflare 单条操作响应。
type cloudflareResp struct {
	Success bool `json:"success"`
	Errors  []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

// dnspodResp DNSPod API 通用响应。
type dnspodResp struct {
	Response struct {
		RecordList []struct {
			RecordId int64  `json:"RecordId"`   // API 返回为数字，使用 int64
			Value    string `json:"Value"`
			Line     string `json:"Line"`
			LineId   string `json:"LineId"`
		} `json:"RecordList"`
		// DescribeDomainList 响应字段（仅 ListDomains 使用，对其他接口为 nil/零值，不影响既有逻辑）。
		DomainList []struct {
			DomainId   int64  `json:"DomainId"`
			DomainName string `json:"Name"`      // API 返回字段名为 "Name"，非 "DomainName"
			Status     string `json:"Status"`
		} `json:"DomainList"`
		TotalCount int64 `json:"TotalCount"`
		Error struct {
			Code    string `json:"Code"`
			Message string `json:"Message"`
		} `json:"Error"`
	} `json:"Response"`
}
