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
	"cfopt/internal/ipsource"
)

// cloudflareBaseURL Cloudflare API 基地址。
const cloudflareBaseURL = "https://api.cloudflare.com/client/v4"

// CloudflareProvider Cloudflare DNS 提供方。
type CloudflareProvider struct {
	apiToken string
	zoneID   string
	client   *HTTPClient
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
	}
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

	common.Info("cf: 同步完成", "domain", fullDomain, "updated", res.Updated, "created", res.Created, "deleted", res.Deleted)
	return res, nil
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
