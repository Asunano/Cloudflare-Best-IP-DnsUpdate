package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"cfopt/internal/common"
)

// WriteDNSPodDomainConf 将单个 DNSPod 域名配置写入 <dir>/dnspod/<domain>.conf（权限 0600）。
// 供 DNSPod 模式/策略切换向导落盘多域名配置。
func WriteDNSPodDomainConf(dir, domain string, cfg *DNSPodConfig) error {
	return writeDomainConf(dir, "dnspod", domain, cfg)
}

// WriteCFDNSDomainConf 将单个 CF DNS 域名配置写入 <dir>/cf-dns/<domain>.conf（权限 0600）。
// 供未来扩展（如 CF 多域名模式切换）复用。
func WriteCFDNSDomainConf(dir, domain string, cfg *CFDNSConfig) error {
	return writeDomainConf(dir, "cf-dns", domain, cfg)
}

// writeDomainConf 将 v 以 JSON 写入 <dir>/<subdir>/<domain>.conf（权限 0600）。
// domain 含路径分隔符或 ".." 时拒绝，避免路径遍历。
func writeDomainConf(dir, subdir, domain string, v any) error {
	if strings.ContainsAny(domain, "/\\") || domain == ".." || strings.Contains(domain, "..") {
		return common.New("config:write-domain-conf", "非法域名（疑似路径遍历）: "+domain)
	}
	sub := filepath.Join(dir, subdir)
	if err := os.MkdirAll(sub, 0o755); err != nil {
		return common.Wrap("config:write-domain-conf:mkdir", err)
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return common.Wrap("config:write-domain-conf:marshal", err)
	}
	p := filepath.Join(sub, domain+".conf")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return common.Wrap("config:write-domain-conf:write", err)
	}
	return nil
}

// ToggleDNSPodMode 切换 DNSPod 工作模式（target: "single" | "isp_lines"）。
//   - 转 isp_lines 且无 ISP 线路时：沿用当前子域/IP 文件建一个"默认"线路，保证配置可用。
//   - 转 single 时：保留 Domain/SubDomain/IPFilePath，清空 ISP map。
func ToggleDNSPodMode(cfg *DNSPodConfig, target string) {
	switch strings.ToLower(target) {
	case "isp_lines":
		cfg.Mode = "isp_lines"
		if len(cfg.ISP) == 0 {
			sub := cfg.SubDomain
			if sub == "" {
				sub = "www"
			}
			ipFile := cfg.IPFilePath
			if ipFile == "" {
				ipFile = "./assets/data/dnspod-dns/" + cfg.Domain + "-默认.iplist"
			}
			isp := ISPConf{Domains: []string{cfg.Domain}}
			isp.IPSource.Files = map[string]string{"默认": ipFile}
			cfg.ISP = map[string]ISPConf{"默认": isp}
		}
	case "single", "":
		cfg.Mode = "single"
		cfg.ISP = nil
	}
}

// ToggleDNSPodStrategy 切换子域策略：unified=true 设 SubDomainUnified（取当前子域或 "all"），
// unified=false 清空 SubDomainUnified（separate 模式）。
func ToggleDNSPodStrategy(cfg *DNSPodConfig, unified bool) {
	if unified {
		if cfg.SubDomainUnified == "" {
			if cfg.SubDomain != "" {
				cfg.SubDomainUnified = cfg.SubDomain
			} else {
				cfg.SubDomainUnified = "all"
			}
		}
	} else {
		cfg.SubDomainUnified = ""
	}
}
