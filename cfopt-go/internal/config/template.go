package config

import (
	"os"
	"path/filepath"

	"cfopt/internal/common"
)

// 默认模板内容（与 conf/*.example 严格对齐）。
const (
	globalTemplate = `{
  "_comment": "全局配置文件 (Go 重写版)",
  "root_dir": "",
  "log_dir": "./logs",
  "log_level": "INFO",
  "lock_dir": "./locks",
  "data_dir": "./assets/data",
  "cache_dir": "./cache",
	"bin_dir": "./assets/bin",
	"schedule": { "interval": "6h" }
}
`

	cfipTemplate = `{
  "_comment": "Cloudflare IP 优选模块配置 (Go 重写版)",
  "enabled": true,
  "cfst": {
    "directory": "./assets/cfst",
    "binary": "cfst",
    "threads": 200,
    "colo": "HKG,NRT",
    "ping_times": 4,
    "download_count": 10,
    "download_time": 10,
    "port": 443,
    "url": "",
    "httping": false,
    "latency_max": 9999,
    "packet_loss_max": 1.0,
    "speed_min": 0,
    "show_count": 20,
    "ip_file": "",
    "disable_download": false,
    "all_ip": false
  },
  "speed_test": {
    "take_ip_num": 5,
    "max_retry": 3,
    "output_html": true,
    "enable_log": true
  },
  "paths": {
    "output_dir": "./assets/data/cf-ip",
    "log_dir": "./logs/cf-ip"
  },
  "cfst_path": ""
}
`

	cfdnsTemplate = `{
  "_comment": "Cloudflare DNS 更新模块配置 (Go 重写版)",
  "enabled": true,
  "api": {
    "token": "your_api_token_here",
    "zone_id": "your_zone_id_here",
    "timeout": 10,
    "max_retries": 5
  },
  "dns": {
    "record_name": "your_dns_name_here",
    "domain": "",
    "max_ips_per_record": 2
  },
  "ip_source": {
    "file_path": "./assets/data/cf-dns/ip_list.iplist",
    "auto_refresh": true,
    "refresh_interval_hours": 6
  },
  "logging": {
    "log_dir": "./logs/cf-dns",
    "log_rotation_days": 7,
    "verbose": false
  }
}
`

	dnspodTemplate = `{
  "_comment": "DNSPod DNS 更新模块配置 (Go 重写版, 支持单线路与多运营商分流)",
  "enabled": true,
  "secret_id": "your_api_id_here",
  "secret_key": "your_api_token_here",
  "mode": "single",
  "domain": "example.com",
  "ttl": 600,
  "max_ips_per_record": 2,
  "sub_domain": "www",
  "sub_domain_unified": "dns",
  "sub_domains": {
    "默认": "default",
    "联通": "unicom",
    "移动": "mobile",
    "电信": "telecom"
  },
  "isp_lines": {
    "默认": {
      "domains": ["example.com"],
      "ip_source": { "files": { "default": "./assets/data/dnspod-dns/default.iplist" } }
    },
    "联通": {
      "domains": ["example.com"],
      "ip_source": { "files": { "unicom": "./assets/data/dnspod-dns/unicom.iplist" } }
    },
    "移动": {
      "domains": ["example.com"],
      "ip_source": { "files": { "mobile": "./assets/data/dnspod-dns/mobile.iplist" } }
    },
    "电信": {
      "domains": ["example.com"],
      "ip_source": { "files": { "telecom": "./assets/data/dnspod-dns/telecom.iplist" } }
    }
  },
  "ip_file": "./assets/data/dnspod-dns/ip_list.iplist",
  "log_dir": "./logs/dnspod-dns",
  "timeout": 10,
  "max_retries": 5
}
`
)

// TemplateContent 返回各配置文件的默认模板内容（与 conf/*.example 对齐）。
func TemplateContent() map[string]string {
	return map[string]string{
		"global.json": globalTemplate,
		"cf-ip.json":  cfipTemplate,
		"cf-dns.json": cfdnsTemplate,
		"dnspod.json": dnspodTemplate,
	}
}

// WriteDefaults 将默认模板写入 dir（仅当文件不存在时），供 `cfopt config init` 使用。
func WriteDefaults(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return common.Wrap("config:write-defaults", err)
	}
	for name, content := range TemplateContent() {
		p := filepath.Join(dir, name)
		if _, err := os.Stat(p); err == nil {
			continue // 已存在，跳过
		}
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			return common.Wrap("config:write "+name, err)
		}
	}
	return nil
}
