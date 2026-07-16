package dns

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/ipsource"
)

// dnspodBaseURL DNSPod API 基地址。
const dnspodBaseURL = "https://dnspod.tencentcloudapi.com"

// DNSPodProvider DNSPod DNS 提供方（支持单线路与多运营商分流）。
type DNSPodProvider struct {
	secretID   string
	secretKey  string
	client     *HTTPClient
	timeout    time.Duration
	maxRetry   int
	domain     string
	subDomain  string
	ttl        int
	subDomains map[string]string
}

// NewDNSPodProvider 从配置构造 DNSPodProvider。
func NewDNSPodProvider(cfg *config.DNSPodConfig) *DNSPodProvider {
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 10
	}
	maxRetry := cfg.MaxRetries
	if maxRetry <= 0 {
		maxRetry = 5
	}
	return &DNSPodProvider{
		secretID:   cfg.SecretID,
		secretKey:  cfg.SecretKey,
		client:     NewHTTPClient(time.Duration(timeout) * time.Second),
		timeout:    time.Duration(timeout) * time.Second,
		maxRetry:   maxRetry,
		domain:     cfg.Domain,
		subDomain:  cfg.SubDomain,
		ttl:        cfg.TTL,
		subDomains: cfg.SubDomains,
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
		body, _, err := p.client.DoRequest(ctx, http.MethodPost, dnspodBaseURL, []byte(payload), headers)
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
			if strings.HasPrefix(resp.Response.Error.Code, "AuthFailure") ||
				strings.HasPrefix(resp.Response.Error.Code, "Unauthorized") {
				return nil, common.New("dnspod:auth", resp.Response.Error.Code+": "+resp.Response.Error.Message)
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
func (p *DNSPodProvider) Sync(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil || !cfg.Enabled {
		common.Info("dnspod: 模块未启用，跳过同步")
		return res, nil
	}
	if strings.EqualFold(cfg.Mode, "isp_lines") {
		return p.syncMulti(ctx, cfg)
	}
	return p.syncSingle(ctx, cfg)
}

func (p *DNSPodProvider) syncSingle(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	ipFile := cfg.IPFilePath
	if strings.TrimSpace(ipFile) == "" {
		return &SyncResult{}, common.New("dnspod:sync", "单线路模式未配置 ip_file")
	}
	sub := p.subDomain
	if sub == "" {
		sub = "www"
	}
	return p.syncLine(ctx, cfg.Domain, sub, "默认", ipFile, cfg.MaxIPsPerRecord, cfg.TTL)
}

func (p *DNSPodProvider) syncMulti(ctx context.Context, cfg *config.DNSPodConfig) (*SyncResult, error) {
	res := &SyncResult{}
	if len(cfg.ISP) == 0 {
		return res, common.New("dnspod:sync", "多线路模式未配置 isp_lines")
	}
	var aggErr error
	for line, conf := range cfg.ISP {
		ipFile := firstIPFile(conf)
		if strings.TrimSpace(ipFile) == "" {
			common.Warn("dnspod: 线路无 IP 文件，跳过", "line", line)
			continue
		}
		sub := p.subDomainForLine(line)
		lineRes, err := p.syncLine(ctx, cfg.Domain, sub, line, ipFile, cfg.MaxIPsPerRecord, cfg.TTL)
		if err != nil {
			res.Errors = append(res.Errors, line+": "+err.Error())
			if aggErr == nil {
				aggErr = err
			}
			continue
		}
		res.Updated += lineRes.Updated
		res.Created += lineRes.Created
		res.Deleted += lineRes.Deleted
	}
	if aggErr != nil {
		return res, common.Wrap("dnspod:sync:multi", aggErr)
	}
	return res, nil
}

// syncLine 单条线路智能同步（记录数一致就地更新，否则删+建），忠实移植原 core.sh 逻辑。
// 返回统计结果 SyncResult（累计 updated/created/deleted）。
func (p *DNSPodProvider) syncLine(ctx context.Context, domain, subDomain, line, ipFile string, maxPerRecord, ttl int) (*SyncResult, error) {
	res := &SyncResult{}
	raw, err := ipsource.Read(ipFile)
	if err != nil {
		return res, common.Wrap("dnspod:sync:read", err)
	}
	targetIPs := dedupeAndValidate(raw, maxPerRecord)
	if len(targetIPs) == 0 {
		return res, common.New("dnspod:sync", "未解析到有效 IP: "+ipFile)
	}

	existing, err := p.listRecords(ctx, domain, subDomain, line)
	if err != nil {
		return res, common.Wrap("dnspod:sync:list", err)
	}

	if needsUpdate(existingIPs(existing), targetIPs) {
		if len(existing) == len(targetIPs) && len(existing) > 0 {
			for i, rec := range existing {
				if rec.Content != targetIPs[i] {
					if err := p.modifyRecord(ctx, domain, subDomain, line, targetIPs[i], ttl, rec.ID); err != nil {
						return res, common.Wrap("dnspod:sync:modify", err)
					}
					res.Updated++
				}
			}
		} else {
			// 删除多余(旧∩¬目标) + 创建缺失(目标∩¬旧)。集合法，不索引复用已删除记录。
			existingSet := make(map[string]string, len(existing)) // content -> id
			for _, rec := range existing {
				existingSet[rec.Content] = rec.ID
			}
			targetSet := make(map[string]bool, len(targetIPs))
			for _, ip := range targetIPs {
				targetSet[ip] = true
			}
			// 删除多余
			for content, id := range existingSet {
				if !targetSet[content] {
					if err := p.deleteRecord(ctx, domain, id); err != nil {
						return res, common.Wrap("dnspod:sync:delete", err)
					}
					res.Deleted++
				}
			}
			// 创建缺失
			for _, ip := range targetIPs {
				if _, ok := existingSet[ip]; !ok {
					if err := p.createRecord(ctx, domain, subDomain, line, ip, ttl); err != nil {
						return res, common.Wrap("dnspod:sync:create", err)
					}
					res.Created++
				}
			}
		}
	}

	common.Info("dnspod: 线路同步完成", "line", line, "updated", res.Updated, "created", res.Created, "deleted", res.Deleted)
	return res, nil
}

func (p *DNSPodProvider) subDomainForLine(line string) string {
	if p.subDomains != nil {
		if s, ok := p.subDomains[line]; ok && s != "" {
			return s
		}
	}
	if p.subDomain != "" {
		return p.subDomain
	}
	return strings.ToLower(line)
}

// firstIPFile 取 ISPConf.IPSource.Files 中首个文件路径。
func firstIPFile(conf config.ISPConf) string {
	for _, v := range conf.IPSource.Files {
		return v
	}
	return ""
}

// existingIPs 从记录列表提取 Content 集合。
func existingIPs(records []Record) []string {
	out := make([]string, 0, len(records))
	for _, r := range records {
		out = append(out, r.Content)
	}
	return out
}
