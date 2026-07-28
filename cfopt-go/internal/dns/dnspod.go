package dns

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
)

// dnspodBaseURL DNSPod API 基地址。声明为 var 以便测试注入 httptest 地址。
var dnspodBaseURL = "https://dnspod.tencentcloudapi.com"

// DNSPodProvider DNSPod DNS 提供方（支持单线路与多运营商分流）。
// 实现 DNSProvider（全局接口）与 LineAwareProvider（多线路接口）。
type DNSPodProvider struct {
	secretID   string
	secretKey  string
	client     *HTTPClient
	timeout    time.Duration
	maxRetry   int
	domain     string
	subDomain  string
	ttl        int
	ttlByLine  map[string]int // 线路名 → TTL 覆盖
	defaultLine string
	subDomains map[string]string
	baseURL    string // API 基地址（默认 dnspodBaseURL，可注入用于测试）
	dataDir    string // 托管状态落盘目录（用于回收不再配置线路的孤儿记录）；空则不持久化/不清理
}

// 编译期接口实现断言：确保 DNSPodProvider 完整实现 LineAwareProvider。
var _ LineAwareProvider = (*DNSPodProvider)(nil)

// NewDNSPodProviderWithCredentials 仅用 SecretID/SecretKey 构造 DNSPodProvider（供校验/取域名，不依赖完整配置）。
func NewDNSPodProviderWithCredentials(secretID, secretKey string) *DNSPodProvider {
	return &DNSPodProvider{
		secretID:   secretID,
		secretKey:  secretKey,
		client:     NewHTTPClient(10 * time.Second),
		timeout:    10 * time.Second,
		maxRetry:   5,
		ttl:        600,
		baseURL:    dnspodBaseURL,
	}
}

// ValidateCredentials 校验 DNSPod 凭证是否有效（调用 DescribeDomainList，复用 sign/call）。
func (p *DNSPodProvider) ValidateCredentials(ctx context.Context) error {
	if strings.TrimSpace(p.secretID) == "" {
		return common.New("dnspod:validate", "secret_id 不能为空")
	}
	if strings.TrimSpace(p.secretKey) == "" {
		return common.New("dnspod:validate", "secret_key 不能为空")
	}
	payload := mustJSON(map[string]any{"Limit": 1})
	if _, err := p.call(ctx, "DescribeDomainList", payload); err != nil {
		return common.Wrap("dnspod:validate", err)
	}
	return nil
}

// ListDomains 列出当前凭证可访问的域名（分页拉取），供快速部署自动选择。
func (p *DNSPodProvider) ListDomains(ctx context.Context) ([]string, error) {
	out := make([]string, 0, 8)
	offset := 0
	for {
		payload := mustJSON(map[string]any{"Offset": offset, "Limit": 100})
		resp, err := p.call(ctx, "DescribeDomainList", payload)
		if err != nil {
			return nil, common.Wrap("dnspod:list-domains", err)
		}
		if len(resp.Response.DomainList) == 0 {
			break
		}
		for _, d := range resp.Response.DomainList {
			if d.DomainName != "" {
				out = append(out, d.DomainName)
			}
		}
		offset += len(resp.Response.DomainList)
		total := resp.Response.TotalCount
		if total > 0 && int64(offset) >= total {
			break
		}
	}
	return out, nil
}

// NewDNSPodProvider 从配置构造 DNSPodProvider。
// NewDNSPodProvider 用 DNSPodConfig 构造提供方（dataDir 为空：不持久化托管状态，不回收孤儿记录）。
func NewDNSPodProvider(cfg *config.DNSPodConfig) *DNSPodProvider {
	return NewDNSPodProviderWithDataDir(cfg, "")
}

// NewDNSPodProviderWithDataDir 同 NewDNSPodProvider，但显式传入 dataDir：
// 非空时会在每次同步后持久化「本域名被管理的线路 → 子域名」映射，并在线路被移除
// （如切回单线路 / 删减 isp_lines）时自动回收对应孤儿 DNS 记录。
func NewDNSPodProviderWithDataDir(cfg *config.DNSPodConfig, dataDir string) *DNSPodProvider {
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 10
	}
	maxRetry := cfg.MaxRetries
	if maxRetry <= 0 {
		maxRetry = 5
	}
	ttl := cfg.TTL
	if ttl <= 0 {
		ttl = 600
	}
	return &DNSPodProvider{
		secretID:   cfg.SecretID,
		secretKey:  cfg.SecretKey,
		client:     NewHTTPClient(time.Duration(timeout) * time.Second),
		timeout:    time.Duration(timeout) * time.Second,
		maxRetry:   maxRetry,
		domain:     cfg.Domain,
		subDomain:  cfg.SubDomain,
		ttl:        ttl,
		ttlByLine:  cfg.TTLByLine,
		defaultLine: cfg.DefaultLine,
		subDomains: cfg.SubDomains,
		baseURL:    dnspodBaseURL,
		dataDir:    dataDir,
	}
}

// NewDNSPodProviderWithCredentialsAndBaseURL 同 NewDNSPodProviderWithCredentials，但可注入 baseURL（用于 httptest 单测）。
func NewDNSPodProviderWithCredentialsAndBaseURL(secretID, secretKey, baseURL string) *DNSPodProvider {
	return &DNSPodProvider{
		secretID:   secretID,
		secretKey:  secretKey,
		client:     NewHTTPClient(10 * time.Second),
		timeout:    10 * time.Second,
		maxRetry:   5,
		ttl:        600,
		baseURL:    baseURL,
	}
}

// sign 生成 DNSPod TC3-HMAC-SHA256 签名头（移植自原 core.sh generate_signature）。
func (p *DNSPodProvider) sign(action, payload string) map[string]string {
	now := time.Now()
	timestamp := fmt.Sprintf("%d", now.Unix())
	date := now.UTC().Format("2006-01-02")

	canonicalHeaders := "content-type:application/json\nhost:dnspod.tencentcloudapi.com\nx-tc-action:" +
		strings.ToLower(action) + "\n"
	signedHeaders := "content-type;host;x-tc-action"

	hashedPayload := sha256Hex(payload)
	canonicalRequest := "POST\n/\n\n" + canonicalHeaders + "\n" + signedHeaders + "\n" + hashedPayload

	hashedCR := sha256Hex(canonicalRequest)
	credentialScope := date + "/dnspod/tc3_request"
	stringToSign := "TC3-HMAC-SHA256\n" + timestamp + "\n" + credentialScope + "\n" + hashedCR

	secretDate := hmacSHA256([]byte("TC3"+p.secretKey), date)
	secretService := hmacSHA256(secretDate, "dnspod")
	secretSigning := hmacSHA256(secretService, "tc3_request")
	signature := hex.EncodeToString(hmacSHA256(secretSigning, stringToSign))

	authorization := "TC3-HMAC-SHA256 Credential=" + p.secretID + "/" + credentialScope +
		", SignedHeaders=" + signedHeaders + ", Signature=" + signature

	return map[string]string{
		"Authorization":  authorization,
		"Content-Type":   "application/json",
		"Host":           "dnspod.tencentcloudapi.com",
		"X-TC-Action":    action,
		"X-TC-Version":   "2021-03-23",
		"X-TC-Timestamp": timestamp,
		"X-TC-Region":    "",
	}
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// call 调用 DNSPod API，带重试（认证错误 AuthFailure/Unauthorized 不重试）。
// 遇「无数据」错误码（记录不存在，确定性错误）返回特型 dnspodNoDataError（不重试）。
func (p *DNSPodProvider) call(ctx context.Context, action string, payload string) (*dnspodResp, error) {
	var last *dnspodResp
	for attempt := 0; attempt < p.maxRetry; attempt++ {
		if attempt > 0 {
			common.Warn("dnspod: 重试 API", "action", action, "attempt", attempt)
			select {
			case <-ctx.Done():
				return nil, common.Wrap("dnspod:ctx", ctx.Err())
			case <-time.After(time.Duration(attempt) * 2 * time.Second):
			}
		}
		headers := p.sign(action, payload)
		body, _, err := p.client.DoRequest(ctx, http.MethodPost, p.baseURL, []byte(payload), headers)
		if err != nil {
			// DoRequest 已处理 429/5xx 重试与 401 不重试；网络错误在此继续重试
			last = nil
			continue
		}
		var resp dnspodResp
		if e := json.Unmarshal(body, &resp); e != nil {
			return nil, common.Wrap("dnspod:decode", e)
		}
		if resp.Response.Error.Code != "" {
			code := resp.Response.Error.Code
			if noDataCodes[code] {
				// 无数据（记录不存在）：确定性错误，不重试，返回特型错误供上层识别。
				return nil, &dnspodNoDataError{code: code, msg: resp.Response.Error.Message}
			}
			if strings.HasPrefix(code, "AuthFailure") ||
				strings.HasPrefix(code, "Unauthorized") {
				return nil, common.New("dnspod:auth", code+": "+resp.Response.Error.Message)
			}
			last = &resp
			continue
		}
		return &resp, nil
	}
	if last != nil {
		return last, common.New("dnspod:api", last.Response.Error.Code+": "+last.Response.Error.Message)
	}
	return nil, common.New("dnspod:api", "重试后仍失败")
}

func mustJSON(v map[string]any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// listRecords 按子域名与线路列出 A 记录。
// 遇「无数据」特型错误时视为空列表返回（P0-1 修复：避免把“记录不存在”当失败）。
func (p *DNSPodProvider) listRecords(ctx context.Context, domain, subDomain, line string) ([]Record, error) {
	payload := mustJSON(map[string]any{
		"Domain":     domain,
		"Subdomain":  subDomain,
		"RecordType": RecordTypeA,
		"RecordLine": line,
		"Limit":      100,
	})
	resp, err := p.call(ctx, "DescribeRecordList", payload)
	if err != nil {
		if IsNoDataError(err) {
			return []Record{}, nil
		}
		return nil, common.Wrap("dnspod:list", err)
	}
	records := make([]Record, 0, len(resp.Response.RecordList))
	for _, r := range resp.Response.RecordList {
		records = append(records, Record{
			ID:      r.RecordId,
			Content: r.Value,
			Line:    r.Line,
		})
	}
	return records, nil
}

func (p *DNSPodProvider) createRecord(ctx context.Context, domain, subDomain, line, value string, ttl int) error {
	payload := mustJSON(map[string]any{
		"Domain":     domain,
		"SubDomain":  subDomain,
		"RecordType": RecordTypeA,
		"RecordLine": line,
		"Value":      value,
		"TTL":        ttl,
	})
	_, err := p.call(ctx, "CreateRecord", payload)
	return common.Wrap("dnspod:create", err)
}

func (p *DNSPodProvider) modifyRecord(ctx context.Context, domain, subDomain, line, value string, ttl int, recordID string) error {
	payload := mustJSON(map[string]any{
		"Domain":     domain,
		"SubDomain":  subDomain,
		"RecordType": RecordTypeA,
		"RecordLine": line,
		"Value":      value,
		"TTL":        ttl,
		"RecordId":   recordID,
	})
	_, err := p.call(ctx, "ModifyRecord", payload)
	return common.Wrap("dnspod:modify", err)
}

func (p *DNSPodProvider) deleteRecord(ctx context.Context, domain string, recordID string) error {
	payload := mustJSON(map[string]any{
		"Domain":   domain,
		"RecordId": recordID,
	})
	_, err := p.call(ctx, "DeleteRecord", payload)
	return common.Wrap("dnspod:delete", err)
}

// ---- LineAwareProvider 实现（供 SyncMultiLine 复用） ----

// ListLineRecords 列出指定子域名+线路的 A 记录。
func (p *DNSPodProvider) ListLineRecords(ctx context.Context, domain, subDomain, line string) ([]Record, error) {
	return p.listRecords(ctx, domain, subDomain, line)
}

// UpsertLineRecord 创建或更新一条记录：按 value 查找已有记录修改，否则新建（建或改）。
// ttl 为默认 TTL；若该线路在 TTLByLine 中配置覆盖，则使用覆盖值。
func (p *DNSPodProvider) UpsertLineRecord(ctx context.Context, domain, subDomain, line, value string, ttl int) error {
	effTTL := ttl
	if p.ttlByLine != nil {
		if v, ok := p.ttlByLine[line]; ok && v > 0 {
			effTTL = v
		}
	}
	existing, err := p.listRecords(ctx, domain, subDomain, line)
	if err != nil {
		return common.Wrap("dnspod:upsert:list", err)
	}
	for _, r := range existing {
		if r.Content == value {
			// 记录已存在：仅在 TTL 变化时修改，避免无谓写。
			if r.TTL != effTTL {
				return common.Wrap("dnspod:upsert:modify", p.modifyRecord(ctx, domain, subDomain, line, value, effTTL, r.ID))
			}
			return nil
		}
	}
	return common.Wrap("dnspod:upsert:create", p.createRecord(ctx, domain, subDomain, line, value, effTTL))
}

// DeleteLineRecord 删除指定 ID 的记录。
func (p *DNSPodProvider) DeleteLineRecord(ctx context.Context, domain, recordID string) error {
	return p.deleteRecord(ctx, domain, recordID)
}

// ---- DNSProvider 接口实现（全局模块兼容） ----

// ListRecords 列出指定子域名的默认线路 A 记录（满足 DNSProvider 接口）。
func (p *DNSPodProvider) ListRecords(ctx context.Context, _ string) ([]Record, error) {
	return p.listRecords(ctx, p.domain, p.subDomain, "默认")
}

// UpsertRecord 创建或更新记录（满足 DNSProvider 接口）。
func (p *DNSPodProvider) UpsertRecord(ctx context.Context, _ string, rec Record) error {
	line := rec.Line
	if line == "" {
		line = "默认"
	}
	sub := p.subDomainForLine(line)
	if rec.ID != "" {
		return p.modifyRecord(ctx, p.domain, sub, line, rec.Content, rec.TTL, rec.ID)
	}
	return p.createRecord(ctx, p.domain, sub, line, rec.Content, rec.TTL)
}

// DeleteRecord 删除指定 ID 的记录（满足 DNSProvider 接口）。
func (p *DNSPodProvider) DeleteRecord(ctx context.Context, _ string, id string) error {
	return p.deleteRecord(ctx, p.domain, id)
}

// Sync 智能同步：根据 mode 执行单线路或多运营商分流，返回统计结果 SyncResult。
// 内部统一走 SyncMultiLine（公共多线路抽象），不再保留 syncLine 散落逻辑。
func (p *DNSPodProvider) Sync(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil || !cfg.Enabled {
		common.Info("dnspod: 模块未启用，跳过同步")
		return res, nil
	}
	resv := NewDNSPodLineResolver(cfg)
	opts := MultiLineOptions{
		UnifiedSubDomain: cfg.SubDomainUnified,
		DefaultLine:      cfg.DefaultLine,
		DeleteMode:       cfg.DeleteMode,
		UnifiedMode:      cfg.SubDomainUnifiedMode,
		GlobalBestFile:   cfg.UnifiedGlobalBestFile,
	}
	lineRes := SyncMultiLine(ctx, resv, p, cfg.Domain, p.ttl, cfg.MaxIPsPerRecord, opts)
	if lineRes == nil {
		return res, nil
	}
	res.Updated = lineRes.Updated
	res.Created = lineRes.Created
	res.Deleted = lineRes.Deleted
	res.Errors = append(res.Errors, lineRes.Errors...)

	// 回收不再配置的线路（孤儿记录）：仅清理此前由 cfopt 管理且当前 Lines() 不再包含的线路。
	p.cleanupOrphanLines(ctx, resv, res)

	return res, nil
}

func (p *DNSPodProvider) syncSingle(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	if strings.TrimSpace(cfg.IPFilePath) == "" {
		return &SyncResult{}, common.New("dnspod:sync", "单线路模式未配置 ip_file")
	}
	resv := NewDNSPodLineResolver(cfg)
	opts := MultiLineOptions{
		UnifiedSubDomain: cfg.SubDomainUnified,
		DefaultLine:      cfg.DefaultLine,
		DeleteMode:       cfg.DeleteMode,
		UnifiedMode:      cfg.SubDomainUnifiedMode,
		GlobalBestFile:   cfg.UnifiedGlobalBestFile,
	}
	return SyncMultiLine(ctx, resv, p, cfg.Domain, p.ttl, cfg.MaxIPsPerRecord, opts), nil
}

func (p *DNSPodProvider) syncMulti(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	if len(cfg.ISP) == 0 {
		return &SyncResult{}, common.New("dnspod:sync", "多线路模式未配置 isp_lines")
	}
	resv := NewDNSPodLineResolver(cfg)
	opts := MultiLineOptions{
		UnifiedSubDomain: cfg.SubDomainUnified,
		DefaultLine:      cfg.DefaultLine,
		DeleteMode:       cfg.DeleteMode,
		UnifiedMode:      cfg.SubDomainUnifiedMode,
		GlobalBestFile:   cfg.UnifiedGlobalBestFile,
	}
	return SyncMultiLine(ctx, resv, p, cfg.Domain, p.ttl, cfg.MaxIPsPerRecord, opts), nil
}

// subDomainForLine 通用「线路 → 子域名」映射（迁至 multiline.resolveSubDomain 的薄封装，保留测试兼容）。
func (p *DNSPodProvider) subDomainForLine(line string) string {
	return resolveSubDomain(line, p.subDomain, p.subDomains)
}

// existingIPs 从记录列表提取 Content 集合。
func existingIPs(records []Record) []string {
	out := make([]string, 0, len(records))
	for _, r := range records {
		out = append(out, r.Content)
	}
	return out
}

// DNSPodLineResolver 把 DNSPodConfig 包装为 LineResolver，供 SyncMultiLine 复用。
// 同时支持单线路（mode=single）与多运营商分流（mode=isp_lines）。
type DNSPodLineResolver struct {
	cfg *config.DNSPodConfig
}

// NewDNSPodLineResolver 构造 DNSPodLineResolver。
func NewDNSPodLineResolver(cfg *config.DNSPodConfig) *DNSPodLineResolver {
	return &DNSPodLineResolver{cfg: cfg}
}

// Lines 返回全部待测线路名：isp_lines 取 ISP map 的 key（排序保证确定性）；
// 单线路返回合成线路 "默认"。
func (r *DNSPodLineResolver) Lines() []string {
	if r.cfg != nil && strings.EqualFold(r.cfg.Mode, "isp_lines") {
		lines := make([]string, 0, len(r.cfg.ISP))
		for line := range r.cfg.ISP {
			lines = append(lines, line)
		}
		sort.Strings(lines)
		return lines
	}
	return []string{"默认"}
}

// ResolveSubDomain 返回某线路对应的子域名。
func (r *DNSPodLineResolver) ResolveSubDomain(line string) string {
	if r.cfg != nil && strings.EqualFold(r.cfg.Mode, "isp_lines") {
		return resolveSubDomain(line, r.cfg.SubDomain, r.cfg.SubDomains)
	}
	sub := r.cfg.SubDomain
	if sub == "" {
		sub = "www"
	}
	return sub
}

// IPFilesForLine 返回某线路对应的 IP 源文件集合。
func (r *DNSPodLineResolver) IPFilesForLine(line string) []string {
	if r.cfg != nil && strings.EqualFold(r.cfg.Mode, "isp_lines") {
		conf, ok := r.cfg.ISP[line]
		if !ok {
			return nil
		}
		return ipFilesOfISP(conf)
	}
	return []string{r.cfg.IPFilePath}
}
