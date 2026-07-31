package dns

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
)

// cloudflareBaseURL Cloudflare API 基地址。
const cloudflareBaseURL = "https://api.cloudflare.com/client/v4"

// minCFTokenLen CF Token 最小长度（仅检查非空，真实验证由 API 调用完成）。
const minCFTokenLen = 1

// Zone Cloudflare 可用 Zone（供安装/快速部署时自动取 Zone ID）。
type Zone struct {
	ID   string // Zone ID
	Name string // 域名（root domain）
}

// CloudflareProvider Cloudflare DNS 提供方。
type CloudflareProvider struct {
	apiToken string
	zoneID   string
	client   *HTTPClient
	history  history.HistoryStore // 可选：异常漂移检测与告警（默认 nil → 跳过）
	baseURL  string               // API 基地址（默认 cloudflareBaseURL，可注入用于测试）
}

// NewCloudflareProvider 从配置构造 CloudflareProvider。
func NewCloudflareProvider(cfg *config.CFDNSConfig) *CloudflareProvider {
	timeout := cfg.API.Timeout
	if timeout <= 0 {
		timeout = 10
	}
	return &CloudflareProvider{
		apiToken: cfg.API.Token,
		zoneID:   cfg.API.ZoneID,
		client:   NewHTTPClient(time.Duration(timeout) * time.Second),
		baseURL:  cloudflareBaseURL,
	}
}

// NewCloudflareProviderWithHistory 构造带历史存储的 CloudflareProvider（用于异常漂移检测）。
func NewCloudflareProviderWithHistory(cfg *config.CFDNSConfig, hist history.HistoryStore) *CloudflareProvider {
	p := NewCloudflareProvider(cfg)
	p.history = hist
	return p
}

// NewCloudflareProviderWithToken 仅用 API Token 构造 CloudflareProvider（供校验/取 Zone，不依赖完整配置）。
func NewCloudflareProviderWithToken(token string) *CloudflareProvider {
	return &CloudflareProvider{
		apiToken: token,
		client:   NewHTTPClient(10 * time.Second),
		baseURL:  cloudflareBaseURL,
	}
}

// NewCloudflareProviderWithTokenAndBaseURL 同 NewCloudflareProviderWithToken，但可注入 baseURL（用于 httptest 单测）。
func NewCloudflareProviderWithTokenAndBaseURL(token, baseURL string) *CloudflareProvider {
	return &CloudflareProvider{
		apiToken: token,
		client:   NewHTTPClient(10 * time.Second),
		baseURL:  baseURL,
	}
}

// ValidateToken 校验 CF API Token 是否有效（调用 GET /user/tokens/verify）。
func (p *CloudflareProvider) ValidateToken(ctx context.Context) error {
	if err := validateCFToken(p.apiToken); err != nil {
		return common.Wrap("cf:validate-token", err)
	}
	url := p.baseURL + "/user/tokens/verify"
	body, _, err := p.client.DoRequest(ctx, http.MethodGet, url, nil, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return common.Wrap("cf:validate-token", err)
	}
	var resp cloudflareResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return common.Wrap("cf:validate-token:decode", err)
	}
	if !resp.Success {
		return common.New("cf:validate-token", "Token 校验失败: "+firstErr(resp.Errors))
	}
	return nil
}

// ListZones 列出当前 Token 可访问的活跃 Zone（取 ID 与域名），供快速部署自动选择。
func (p *CloudflareProvider) ListZones(ctx context.Context) ([]Zone, error) {
	url := p.baseURL + "/zones?status=active&per_page=50"
	body, _, err := p.client.DoRequest(ctx, http.MethodGet, url, nil, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return nil, common.Wrap("cf:list-zones", err)
	}
	var resp struct {
		Success bool `json:"success"`
		Errors  []struct {
			Message string `json:"message"`
		} `json:"errors"`
		Result []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, common.Wrap("cf:list-zones:decode", err)
	}
	if !resp.Success {
		return nil, common.New("cf:list-zones", "API 失败: "+firstErr(resp.Errors))
	}
	zones := make([]Zone, 0, len(resp.Result))
	for _, z := range resp.Result {
		zones = append(zones, Zone{ID: z.ID, Name: z.Name})
	}
	return zones, nil
}

// validateCFToken 校验 CF Token 非空（长度≥1），真实验证由 API 调用完成。
func validateCFToken(token string) error {
	if strings.TrimSpace(token) == "" {
		return fmt.Errorf("cfopt: cf token 为空")
	}
	if len(token) < minCFTokenLen {
		return fmt.Errorf("cfopt: cf token 长度不足（需 ≥%d，当前 %d）", minCFTokenLen, len(token))
	}
	return nil
}

// validateHostname 校验合法主机名/子域名（标签：字母/数字/连字符，不以连字符起止，长度 ≤63）。
func validateHostname(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("cfopt: 空主机名")
	}
	if len(name) > 253 {
		return fmt.Errorf("cfopt: 主机名过长: %q", name)
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 {
			return fmt.Errorf("cfopt: 非法主机名标签: %q", label)
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return fmt.Errorf("cfopt: 主机名标签不能以连字符开头/结尾: %q", label)
		}
		for _, c := range label {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') {
				return fmt.Errorf("cfopt: 主机名含非法字符: %q", label)
			}
		}
	}
	return nil
}

// setEqual 判断两个字符串集合是否相等。
func setEqual(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// buildFullDomain 构建完整域名：@ → 根域名；其他 → name.domain。
func buildFullDomain(name, domain string) string {
	if strings.TrimSpace(name) == "@" {
		return domain
	}
	return fmt.Sprintf("%s.%s", name, domain)
}

// ListRecords 列出指定完整域名的 A 类型记录。
func (p *CloudflareProvider) ListRecords(ctx context.Context, domain string) ([]Record, error) {
	url := fmt.Sprintf("%s/zones/%s/dns_records?type=A&name=%s", cloudflareBaseURL, p.zoneID, domain)
	body, _, err := p.client.DoRequest(ctx, http.MethodGet, url, nil, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return nil, common.Wrap("cf:list", err)
	}
	var resp cloudflareListResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, common.Wrap("cf:list:decode", err)
	}
	if !resp.Success {
		return nil, common.New("cf:list", "API 失败: "+firstErr(resp.Errors))
	}
	records := make([]Record, 0, len(resp.Result))
	for _, r := range resp.Result {
		records = append(records, Record{
			ID:      r.ID,
			Name:    r.Name,
			Type:    r.Type,
			Content: r.Content,
			TTL:     r.TTL,
			Proxied: r.Proxied,
		})
	}
	return records, nil
}

// UpsertRecord 创建或更新记录（有 ID 则更新，无 ID 则创建）。
func (p *CloudflareProvider) UpsertRecord(ctx context.Context, domain string, rec Record) error {
	if rec.ID != "" {
		return p.updateRecord(ctx, domain, rec)
	}
	return p.createRecord(ctx, domain, rec)
}

func (p *CloudflareProvider) updateRecord(ctx context.Context, domain string, rec Record) error {
	url := fmt.Sprintf("%s/zones/%s/dns_records/%s", cloudflareBaseURL, p.zoneID, rec.ID)
	payload, _ := json.Marshal(map[string]any{
		"type":    rec.Type,
		"name":    domain,
		"content": rec.Content,
		"ttl":     rec.TTL,
		"proxied": rec.Proxied,
	})
	body, _, err := p.client.DoRequest(ctx, http.MethodPut, url, payload, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return common.Wrap("cf:update", err)
	}
	var resp cloudflareResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return common.Wrap("cf:update:decode", err)
	}
	if !resp.Success {
		return common.New("cf:update", "API 失败: "+firstErr(resp.Errors))
	}
	return nil
}

func (p *CloudflareProvider) createRecord(ctx context.Context, domain string, rec Record) error {
	url := fmt.Sprintf("%s/zones/%s/dns_records", cloudflareBaseURL, p.zoneID)
	ttl := rec.TTL
	if ttl <= 0 {
		ttl = 1
	}
	payload, _ := json.Marshal(map[string]any{
		"type":    rec.Type,
		"name":    domain,
		"content": rec.Content,
		"ttl":     ttl,
		"proxied": rec.Proxied,
	})
	body, _, err := p.client.DoRequest(ctx, http.MethodPost, url, payload, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return common.Wrap("cf:create", err)
	}
	var resp cloudflareResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return common.Wrap("cf:create:decode", err)
	}
	if !resp.Success {
		return common.New("cf:create", "API 失败: "+firstErr(resp.Errors))
	}
	return nil
}

// DeleteRecord 删除指定 ID 的记录。
func (p *CloudflareProvider) DeleteRecord(ctx context.Context, domain string, id string) error {
	url := fmt.Sprintf("%s/zones/%s/dns_records/%s", cloudflareBaseURL, p.zoneID, id)
	body, _, err := p.client.DoRequest(ctx, http.MethodDelete, url, nil, map[string]string{
		"Authorization": "Bearer " + p.apiToken,
	})
	if err != nil {
		return common.Wrap("cf:delete", err)
	}
	var resp cloudflareResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return common.Wrap("cf:delete:decode", err)
	}
	if !resp.Success {
		return common.New("cf:delete", "API 失败: "+firstErr(resp.Errors))
	}
	return nil
}

// Sync 智能同步：读取 IP 源文件 → 去重校验 → 与线上记录对比 → 就地更新/删除+创建。
// 记录数一致时就地更新（0 次删除），否则删除多余 + 创建新记录，忠实移植原 core.sh 逻辑。
// 返回统计结果 SyncResult（累计 updated/created/deleted）。
func (p *CloudflareProvider) Sync(ctx context.Context, cfg *config.CFDNSConfig) (*SyncResult, error) {
	res := &SyncResult{}
	if cfg == nil || !cfg.Enabled {
		common.Info("cf: 模块未启用，跳过同步")
		return res, nil
	}
	// F3/F4：IP 源文件前置检测（过期警告 + 数量剧变警告），非阻断；结果并入 res.Warnings。
	if warns := CheckIPSources([]string{cfg.IPSource.FilePath}, IPSourceCheckOpts{}); len(warns) > 0 {
		res.Warnings = append(res.Warnings, warns...)
	}
	ipFile := cfg.IPSource.FilePath
	if strings.TrimSpace(ipFile) == "" {
		return res, common.New("cf:sync", "未配置 ip_source.file_path")
	}
	raw, err := ipsource.Read(ipFile)
	if err != nil {
		return res, common.Wrap("cf:sync:read", err)
	}

	targetIPs := dedupeAndValidate(raw, cfg.DNS.MaxIPsPerRecord)
	if len(targetIPs) == 0 {
		return res, common.New("cf:sync", "未解析到有效 IP")
	}

	fullDomain := buildFullDomain(cfg.DNS.RecordName, cfg.DNS.Domain)

	// P2-3：CF Token 与 DNS 名校验（非法配置直接失败，避免无效 API 调用）。
	if err := validateCFToken(cfg.API.Token); err != nil {
		return res, common.Wrap("cf:validate:token", err)
	}
	if err := validateHostname(fullDomain); err != nil {
		return res, common.Wrap("cf:validate:name", err)
	}

	existing, err := p.ListRecords(ctx, fullDomain)
	if err != nil {
		return res, common.Wrap("cf:sync:list", err)
	}

	existingIPs := make([]string, 0, len(existing))
	for _, r := range existing {
		existingIPs = append(existingIPs, r.Content)
	}

	if needsUpdate(existingIPs, targetIPs) {
		if len(existing) == len(targetIPs) && len(existing) > 0 {
			// 记录数一致 → 就地更新
			for i, rec := range existing {
				if rec.Content != targetIPs[i] {
					if err := p.UpsertRecord(ctx, fullDomain, Record{
						ID:      rec.ID,
						Name:    fullDomain,
						Type:    RecordTypeA,
						Content: targetIPs[i],
						TTL:     rec.TTL,
						Proxied: rec.Proxied,
					}); err != nil {
						return res, common.Wrap("cf:sync:update", err)
					}
					res.Updated++
				}
			}
		} else {
			// 记录数不一致 → 删除多余(旧∩¬目标) + 创建缺失(目标∩¬旧)。集合法，绝不索引复用已删除记录。
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
					if err := p.DeleteRecord(ctx, fullDomain, id); err != nil {
						return res, common.Wrap("cf:sync:delete", err)
					}
					res.Deleted++
				}
			}
			// 创建缺失
			for _, ip := range targetIPs {
				if _, ok := existingSet[ip]; !ok {
					rec := Record{Name: fullDomain, Type: RecordTypeA, Content: ip, TTL: 1, Proxied: false}
					if err := p.UpsertRecord(ctx, fullDomain, rec); err != nil {
						return res, common.Wrap("cf:sync:upsert", err)
					}
					res.Created++
				}
			}
		}
	}

	// P2-3 同步后漂移检测 + 一致性校验（仅配置了 history 时做线上重查）。
	p.postSyncProtect(ctx, fullDomain, existingIPs, targetIPs)

	// 成功则记录历史（供后续漂移/过期检测）。
	if p.history != nil {
		_ = p.history.Append(history.HistoryEntry{
			Action:  "sync.cf",
			Detail:  fmt.Sprintf("domain=%s updated=%d created=%d deleted=%d", fullDomain, res.Updated, res.Created, res.Deleted),
			Success: true,
		})
	}

	common.Info("cf: 同步完成", "domain", fullDomain, "updated", res.Updated, "created", res.Created, "deleted", res.Deleted)
	return res, nil
}

// cfDriftWarnRatio IP 数量漂移告警阈值（前后差异占比）。
const cfDriftWarnRatio = 0.5

// cfStaleWarnDuration 距上次成功同步超过此时长则告警（默认 48h）。
const cfStaleWarnDuration = 48 * time.Hour

// postSyncProtect 同步后保护：线上重查做一致性校验，并按漂移比例/过期时长告警+写历史。
// history 为 nil 时仅做本地估算（不重查），避免无谓 API 调用。
func (p *CloudflareProvider) postSyncProtect(ctx context.Context, fullDomain string, before, after []string) {
	targetSet := make(map[string]bool, len(after))
	for _, ip := range after {
		targetSet[ip] = true
	}

	// 1) 一致性校验：线上记录应与期望目标一致（与线上记录比对，不一致告警）。
	if p.history != nil {
		online, listErr := p.ListRecords(ctx, fullDomain)
		if listErr != nil {
			common.Warn("cf: 同步后重查失败，跳过一致性校验", "err", listErr.Error())
		} else {
			onlineSet := make(map[string]bool, len(online))
			for _, r := range online {
				onlineSet[r.Content] = true
			}
			if !setEqual(onlineSet, targetSet) {
				common.Warn("cf: IP 一致性校验失败：线上记录与期望目标不一致", "domain", fullDomain)
				_ = p.history.Append(history.HistoryEntry{
					Action:  "sync.cf.consistency",
					Detail:  fmt.Sprintf("domain=%s 线上记录与期望目标不一致", fullDomain),
					Success: false,
				})
			}
		}
	}

	// 2) 漂移检测：前后 IP 数量差异超过阈值 → 告警 + 写历史。
	if len(before) > 0 {
		diff := float64(absInt(len(after)-len(before))) / float64(len(before))
		if diff > cfDriftWarnRatio {
			msg := fmt.Sprintf("cf: IP 数量漂移 %.0f%%（前 %d → 后 %d），请确认测速结果", diff*100, len(before), len(after))
			common.Warn(msg, "domain", fullDomain)
			if p.history != nil {
				_ = p.history.Append(history.HistoryEntry{
					Action:  "sync.cf.drift",
					Detail:  msg,
					Success: false,
				})
			}
		}
	}

	// 3) 过期检测：距上次成功同步超过 48h → 告警 + 写历史。
	if p.history != nil {
		recs, readErr := p.history.ReadLatest(20)
		if readErr == nil {
			for _, e := range recs {
				if e.Action == "sync.cf" && e.Success {
					if time.Since(e.Timestamp) > cfStaleWarnDuration {
						msg := fmt.Sprintf("cf: 距上次成功同步已超 %s，可能存在异常", cfStaleWarnDuration)
						common.Warn(msg, "domain", fullDomain, "last", e.Timestamp.Format(time.RFC3339))
						_ = p.history.Append(history.HistoryEntry{
							Action:  "sync.cf.stale",
							Detail:  msg,
							Success: false,
						})
					}
					break // 找到最近一次成功同步即可
				}
			}
		}
	}
}

// absInt 整数绝对值。
func absInt(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// firstErr 取错误列表首条消息。
func firstErr(errs []struct {
	Message string `json:"message"`
}) string {
	if len(errs) > 0 {
		return errs[0].Message
	}
	return "未知错误"
}
