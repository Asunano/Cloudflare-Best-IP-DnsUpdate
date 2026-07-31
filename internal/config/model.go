// Package config 定义 cfopt 的配置模型与加载/校验逻辑。
// 配置结构字段与 conf/*.example 示例 JSON 严格对齐（见各结构体 json tag）。
package config

import "encoding/json"

// DefaultGlobalBestIPFile 全局最优 IP 文件默认路径。
const DefaultGlobalBestIPFile = "./assets/data/cf-ip/best.iplist"

// ===== 全局配置（global.json） =====

// GlobalConfig 系统级设置。
type GlobalConfig struct {
	RootDir  string         `json:"root_dir,omitempty"`  // 项目根目录，用于解析相对路径
	LogDir   string         `json:"log_dir"`             // 日志目录
	LogLevel string         `json:"log_level"`           // 日志级别: DEBUG/INFO/WARN/ERROR
	LockDir  string         `json:"lock_dir"`            // 进程锁目录
	DataDir  string         `json:"data_dir,omitempty"`  // 数据目录
	CacheDir string         `json:"cache_dir,omitempty"` // 缓存目录
	BinDir   string         `json:"bin_dir,omitempty"`   // 二进制目录（cfst 等）
	Schedule ScheduleConfig `json:"schedule,omitempty"`  // 调度/daemon 配置（间隔等）
	// SpeedTest 测速全局参数（cf-ip.json 已废弃，全局参数迁移至此）。
	SpeedTest GlobalSpeedTestConfig `json:"speed_test,omitempty"`
}

// ScheduleConfig 调度/daemon 配置。
type ScheduleConfig struct {
	Interval string `json:"interval,omitempty"` // Go duration 字符串，如 "6h"；空则默认 6h
	// WatchdogTimeout 单次调度（测速+同步）的看门狗超时，Go duration 字符串，如 "40m"。
	// 非空时直接采用（优先于按测速任务数自动估算）；空则按串行 cfst 测速任务数自动估算。
	WatchdogTimeout string `json:"watchdog_timeout,omitempty"`
}

// GlobalSpeedTestConfig 测速全局参数。
type GlobalSpeedTestConfig struct {
	MaxRetry int `json:"max_retry,omitempty"` // 测速失败自动重试次数（默认 3）
}

// ===== 测速参数结构（已移除 CFSTConfig，所有参数走 cfst 内置默认值） =====

// ===== Cloudflare DNS 配置（cf-dns.json / cf-dns/{domain}.conf） =====

// CloudflareAPIConfig Cloudflare API 认证与超时配置。
type CloudflareAPIConfig struct {
	Token      string `json:"token"`
	ZoneID     string `json:"zone_id"`
	Timeout    int    `json:"timeout"`
	MaxRetries int    `json:"max_retries"`
}

// CloudflareDNSConfig Cloudflare 记录与域名配置。
type CloudflareDNSConfig struct {
	RecordName      string `json:"record_name"`
	Domain          string `json:"domain"`
	MaxIPsPerRecord int    `json:"max_ips_per_record"`
}

// CloudflareIPSourceConfig Cloudflare IP 数据源配置。
type CloudflareIPSourceConfig struct {
	FilePath             string `json:"file_path"`
	AutoRefresh          bool   `json:"auto_refresh"`
	RefreshIntervalHours int    `json:"refresh_interval_hours"`
}

// CloudflareLoggingConfig Cloudflare 日志配置。
type CloudflareLoggingConfig struct {
	LogDir          string `json:"log_dir"`
	LogRotationDays int    `json:"log_rotation_days"`
	Verbose         bool   `json:"verbose"`
}

// CFDNSConfig Cloudflare DNS 同步配置。
type CFDNSConfig struct {
	Enabled  bool                     `json:"enabled"`
	API      CloudflareAPIConfig      `json:"api"`
	DNS      CloudflareDNSConfig      `json:"dns"`
	IPSource CloudflareIPSourceConfig `json:"ip_source"`
	Logging  CloudflareLoggingConfig  `json:"logging"`
	// SpeedTestColo 按域名覆盖测速地区（逗号分隔，如 "HKG,NRT"）。
	// 非空时该域名在 sync 阶段获得独立测速结果。
	SpeedTestColo string `json:"speed_test_colo,omitempty"`
	// TakeIPNum 每次同步从测速结果中提取的最优 IP 条数（默认 5）。
	TakeIPNum int `json:"take_ip_num,omitempty"`
}

// ===== DNSPod 配置（dnspod.json / dnspod/{domain}.conf） =====

// ISPConf 单运营商线路配置（多运营商分流 mode=isp_lines 时使用）。
type ISPConf struct {
	Domains  []string `json:"domains"`
	IPSource struct {
		Files map[string]string `json:"files"`
	} `json:"ip_source"`
	// SpeedTestColo 该线路独立测速地区（逗号分隔，如 "HKG,NRT"）；空=沿用全局。
	SpeedTestColo string `json:"speed_test_colo,omitempty"`
	// SpeedTestIPFile 该线路独立 IP 数据文件；空=使用默认 ip.txt。
	SpeedTestIPFile string `json:"speed_test_ip_file,omitempty"`
}

// DNSPodConfig DNSPod DNS 同步配置。
type DNSPodConfig struct {
	Enabled   bool               `json:"enabled"`
	SecretID  string             `json:"secret_id"`
	SecretKey string             `json:"secret_key"`
	Mode      string             `json:"mode"`
	ISP       map[string]ISPConf `json:"isp_lines"`

	// 单线路兼容字段（mode=single 时使用）
	Domain                string            `json:"domain"`
	TTL                   int               `json:"ttl"`
	MaxIPsPerRecord       int               `json:"max_ips_per_record"`
	SubDomain             string            `json:"sub_domain"`
	SubDomainUnified      string            `json:"sub_domain_unified"`
	SubDomainUnifiedMode  string            `json:"sub_domain_unified_mode,omitempty"`
	UnifiedGlobalBestFile string            `json:"unified_global_best_file,omitempty"`
	SubDomains            map[string]string `json:"sub_domains"`
	IPFilePath            string            `json:"ip_file"`
	LogDir                string            `json:"log_dir"`
	Timeout               int               `json:"timeout"`
	MaxRetries            int               `json:"max_retries"`

	// 多线路增强字段（mode=isp_lines 时使用）
	DefaultLine     string         `json:"default_line,omitempty"`
	TTLByLine       map[string]int `json:"ttl_by_line,omitempty"`
	DeleteMode      string         `json:"delete_mode,omitempty"`
	SpeedTestPerISP bool           `json:"speed_test_per_isp,omitempty"`
	// SpeedTestColo 按域名覆盖测速地区（逗号分隔，如 "HKG,NRT"）。
	// 非空时该域名在 sync 阶段获得独立测速结果。与 CF DNS 的 SpeedTestColo 语义一致。
	SpeedTestColo string `json:"speed_test_colo,omitempty"`
	// TakeIPNum 每次同步从测速结果中提取的最优 IP 条数（默认 5）。
	TakeIPNum int `json:"take_ip_num,omitempty"`
}

// Config 聚合全部配置。
type Config struct {
	Global *GlobalConfig `json:"global,omitempty"`

	// CF-DNS 单域名配置（cf-dns.json，已废弃，建议使用 CFDNSDomains 多域名方式）。
	CFDNS *CFDNSConfig `json:"cf_dns,omitempty"`
	// DNSPod 单域名配置（dnspod.json，已废弃）。
	DNSPod *DNSPodConfig `json:"dnspod,omitempty"`

	// CFDNSDomains 多域名配置：key=域名。conf/cf-dns/{domain}.conf
	CFDNSDomains map[string]*CFDNSConfig `json:"cf_dns_domains,omitempty"`
	// DNSPodDomains 多域名配置：key=域名。conf/dnspod/{domain}.conf
	DNSPodDomains map[string]*DNSPodConfig `json:"dnspod_domains,omitempty"`

	// Modules 扩展钩子。
	Modules map[string]json.RawMessage `json:"modules,omitempty"`
}
