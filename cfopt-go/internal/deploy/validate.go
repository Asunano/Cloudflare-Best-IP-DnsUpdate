// Package deploy 提供「安装/快速部署/配置向导」共用的校验与部署编排能力：
//   - ValidateCloudflare / ValidateDNSPod：凭证校验并自动取回 Zone/域名列表（wizard 与 quickdeploy 共用）。
//   - DeployPlan：一次向导收集结果的统一结构；BuildConf 转为可被 config 扫描加载的 conf 结构。
//
// 本包仅做「最小、向后兼容」的入口封装：底层复用 internal/dns 既有 HTTP 客户端，
// 不改动既有 Sync 逻辑。新增能力零侵入现有同步链路。
package deploy

import (
	"context"
	"fmt"
	"strings"

	"cfopt/internal/config"
	"cfopt/internal/dns"
)

// Zone Cloudflare 可用 Zone（类型别名，等价于 dns.Zone，避免 cmd 直接耦合 dns 细节）。
type Zone = dns.Zone

// DNSPodLineEnum 多线路固定枚举（与 dnspod.json 模板一致）。
// 用户按 Q3 以逗号编号（1,3,5）选择，映射到本枚举。
var DNSPodLineEnum = []string{"默认", "联通", "移动", "电信"}

// ParseLineSelection 将 Q3 的多线路编号输入（如 "1,3,5"）映射为线路名列表。
// 空输入返回单线路默认 ["默认"]；非法编号被忽略；去重保序。
func ParseLineSelection(input string) []string {
	input = strings.TrimSpace(input)
	if input == "" {
		return []string{"默认"}
	}
	seen := make(map[string]bool)
	var out []string
	for _, part := range strings.Split(input, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		idx := 0
		if _, err := fmt.Sscanf(part, "%d", &idx); err != nil || idx < 1 || idx > len(DNSPodLineEnum) {
			continue
		}
		line := DNSPodLineEnum[idx-1]
		if !seen[line] {
			seen[line] = true
			out = append(out, line)
		}
	}
	if len(out) == 0 {
		return []string{"默认"}
	}
	return out
}

// ValidateCloudflare 校验 CF Token 并取回 Zone 列表（空 token 直接报错）。
func ValidateCloudflare(ctx context.Context, token string) ([]Zone, error) {
	return validateCloudflareWithBaseURL(ctx, token, "")
}

// validateCloudflareWithBaseURL 同 ValidateCloudflare，但可注入 baseURL（用于 httptest 单测）。
func validateCloudflareWithBaseURL(ctx context.Context, token, baseURL string) ([]Zone, error) {
	var p *dns.CloudflareProvider
	if baseURL != "" {
		p = dns.NewCloudflareProviderWithTokenAndBaseURL(token, baseURL)
	} else {
		p = dns.NewCloudflareProviderWithToken(token)
	}
	if err := p.ValidateToken(ctx); err != nil {
		return nil, err
	}
	return p.ListZones(ctx)
}

// ValidateDNSPod 校验 DNSPod 凭证并取回域名列表（凭证错误明确返回）。
func ValidateDNSPod(ctx context.Context, secretID, secretKey string) ([]string, error) {
	return validateDNSPodWithBaseURL(ctx, secretID, secretKey, "")
}

// validateDNSPodWithBaseURL 同 ValidateDNSPod，但可注入 baseURL（用于 httptest 单测）。
func validateDNSPodWithBaseURL(ctx context.Context, secretID, secretKey, baseURL string) ([]string, error) {
	var p *dns.DNSPodProvider
	if baseURL != "" {
		p = dns.NewDNSPodProviderWithCredentialsAndBaseURL(secretID, secretKey, baseURL)
	} else {
		p = dns.NewDNSPodProviderWithCredentials(secretID, secretKey)
	}
	if err := p.ValidateCredentials(ctx); err != nil {
		return nil, err
	}
	return p.ListDomains(ctx)
}

// DeployPlan quickdeploy / config wizard 的收集结果。
type DeployPlan struct {
	Provider         string   // "cloudflare" | "dnspod"
	Token            string   // CF: API Token；DNSPod 留空
	SecretID         string   // DNSPod 专用
	SecretKey        string   // DNSPod 专用
	ZoneID           string   // CF Zone ID
	Domain           string   // 域名（root domain）
	RecordName       string   // CF 子域名（如 www / @）；DNSPod 用 SubDomain
	SubDomain        string   // DNSPod 子域名
	Lines            []string // DNSPod 多线路线路名（默认/联通/移动/电信）；CF 为空=单记录
	Colo             string   // 测速地区（逗号分隔，如 "HKG,NRT"；空=不限地区）
	TakeIPNum        int      // 同步 IP 数量（每次同步提取的最优 IP 条数），0 表示使用默认值
	ScheduleInterval string   // 调度间隔，默认 "6h"
}

// BuildConf 把 DeployPlan 转为可被 loader 扫描的 conf 结构（CF→*config.CFDNSConfig，DNSPod→*config.DNSPodConfig）。
func (p *DeployPlan) BuildConf() (any, error) {
	switch strings.ToLower(p.Provider) {
	case "cloudflare":
		recordName := strings.TrimSpace(p.RecordName)
		if recordName == "" {
			recordName = "@"
		}
		domain := strings.TrimSpace(p.Domain)
		if domain == "" {
			return nil, fmt.Errorf("deploy: CF 配置缺少域名")
		}
		cfg := &config.CFDNSConfig{
			Enabled: true,
			API: config.CloudflareAPIConfig{
				Token:      p.Token,
				ZoneID:     p.ZoneID,
				Timeout:    10,
				MaxRetries: 5,
			},
			DNS: config.CloudflareDNSConfig{
				RecordName:      recordName,
				Domain:          domain,
				MaxIPsPerRecord: 2,
			},
			IPSource: config.CloudflareIPSourceConfig{
				FilePath:             "./assets/data/cf-dns/" + domain + ".iplist",
				AutoRefresh:          true,
				RefreshIntervalHours: 6,
			},
		}
		return cfg, nil

	case "dnspod":
		domain := strings.TrimSpace(p.Domain)
		if domain == "" {
			return nil, fmt.Errorf("deploy: DNSPod 配置缺少域名")
		}
		subDomain := strings.TrimSpace(p.SubDomain)
		if subDomain == "" {
			subDomain = "www"
		}
		cfg := &config.DNSPodConfig{
			Enabled:         true,
			SecretID:        p.SecretID,
			SecretKey:       p.SecretKey,
			Mode:            "single",
			Domain:          domain,
			TTL:             600,
			MaxIPsPerRecord: 2,
			SubDomain:       subDomain,
			IPFilePath:      "./assets/data/dnspod-dns/" + domain + ".iplist",
			Timeout:         10,
			MaxRetries:      5,
		}
		if len(p.Lines) > 1 {
			cfg.Mode = "isp_lines"
			cfg.ISP = make(map[string]config.ISPConf, len(p.Lines))
			for _, line := range p.Lines {
				isp := config.ISPConf{Domains: []string{domain}}
				isp.IPSource.Files = map[string]string{
					line: "./assets/data/dnspod-dns/" + domain + "-" + line + ".iplist",
				}
				cfg.ISP[line] = isp
			}
		}
		return cfg, nil

	default:
		return nil, fmt.Errorf("deploy: 未知服务商 %q", p.Provider)
	}
}

// ConfSubDir 返回该 plan 对应 conf 子目录（cf-dns 或 dnspod）。
func (p *DeployPlan) ConfSubDir() string {
	if strings.EqualFold(p.Provider, "cloudflare") {
		return "cf-dns"
	}
	return "dnspod"
}

// ConfFileName 返回 conf 文件名（域名.conf）。
func (p *DeployPlan) ConfFileName() string {
	domain := strings.TrimSpace(p.Domain)
	if domain == "" {
		domain = "unknown"
	}
	return domain + ".conf"
}
