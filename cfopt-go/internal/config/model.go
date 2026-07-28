// Package config 定义 cfopt 的配置模型与加载/校验逻辑。
// 配置结构字段与 conf/*.example 示例 JSON 严格对齐（见各结构体 json tag）。
package config

import "encoding/json"

// DefaultGlobalBestIPFile 全局最优 IP 文件默认路径（强制 .iplist 落盘，防 .txt 误解析）。
const DefaultGlobalBestIPFile = "./assets/data/cf-ip/best.iplist"

// ===== 全局配置（global.json） =====

// GlobalConfig 系统级设置。
type GlobalConfig struct {
	RootDir   string `json:"root_dir,omitempty"` // 项目根目录，用于解析相对路径
	LogDir    string `json:"log_dir"`            // 日志目录
	LogLevel  string `json:"log_level"`          // 日志级别: DEBUG/INFO/WARN/ERROR
	LockDir   string `json:"lock_dir"`           // 进程锁目录
	DataDir   string `json:"data_dir,omitempty"` // 数据目录
	CacheDir  string `json:"cache_dir,omitempty"`// 缓存目录
	BinDir    string `json:"bin_dir,omitempty"`  // 二进制目录（cfst 等）
	Schedule  ScheduleConfig `json:"schedule,omitempty"` // 调度/daemon 配置（间隔等）
}

// ScheduleConfig 调度/daemon 配置。
type ScheduleConfig struct {
	Interval string `json:"interval,omitempty"` // Go duration 字符串，如 "6h"；空则默认 6h
}

// ===== Cloudflare IP 优选配置（cf-ip.json） =====

// CFSTConfig cfst 测速二进制相关配置（与现有模板 cf-ip.json.example 形态对齐）。
type CFSTConfig struct {
	Directory       string  `json:"directory"`
	Binary          string  `json:"binary"`
	Threads         int     `json:"threads"`
	Colo            string  `json:"colo"` // 逗号分隔的地区码，如 "HKG,NRT"
	PingTimes       int     `json:"ping_times"`
	DownloadCount   int     `json:"download_count"`
	DownloadTime    int     `json:"download_time"`
	Port            int     `json:"port"`
	URL             string  `json:"url"`
	Httping         bool    `json:"httping"`
	LatencyMax      float64 `json:"latency_max"`
	PacketLossMax   float64 `json:"packet_loss_max"`
	SpeedMin        float64 `json:"speed_min"`
	ShowCount       int     `json:"show_count"`
	IPFile          string  `json:"ip_file"`
	DisableDownload bool    `json:"disable_download"`
	AllIP           bool    `json:"all_ip"`
}

// SpeedTestConfig 测速结果处理相关配置。
type SpeedTestConfig struct {
	TakeIPNum  int  `json:"take_ip_num"`
	MaxRetry   int  `json:"max_retry"`
	OutputHTML bool `json:"output_html"`
	EnableLog  bool `json:"enable_log"`
}

// PathConfig 路径相关配置。
type PathConfig struct {
	OutputDir string `json:"output_dir"`
	LogDir    string `json:"log_dir"`
	// GlobalBestFile 全局最优 IP 文件路径（由 sync 阶段强制 .iplist 落盘，供 global_best 统一子域模式读取）。
	GlobalBestFile string `json:"global_best_file,omitempty"`
}

// CFIPConfig Cloudflare IP 优选配置。
type CFIPConfig struct {
	Enabled   bool            `json:"enabled"`
	CFST      CFSTConfig      `json:"cfst"`
	SpeedTest SpeedTestConfig `json:"speed_test"`
	Paths     PathConfig      `json:"paths"`
	// CFSTPath 可选：显式覆盖 cfst 二进制路径，优先级高于 assets/cfst/cfst[.exe] 探测。
	CFSTPath string `json:"cfst_path,omitempty"`
}

// ===== Cloudflare DNS 配置（cf-dns.json） =====

// CloudflareAPIConfig Cloudflare API 认证与超时配置。
type CloudflareAPIConfig struct {
	Token      string `json:"token"`
	ZoneID     string `json:"zone_id"`
	Timeout    int    `json:"timeout"`
	MaxRetries int    `json:"max_retries"`
}

// CloudflareDNSConfig Cloudflare 记录与域名配置。
type CloudflareDNSConfig struct {
	RecordName      string `json:"record_name"` // 子域名: dns/cf/@(根域名)
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
}

// ===== DNSPod 配置（dnspod.json） =====

// ISPSpeedTestConfig 单运营商线路的独立测速参数（mode=isp_lines 且 speed_test_per_isp=true 时使用）。
// 字段与 CFSTConfig 对应子集对齐，供 buildPerLineCFIP 合并进全局 CFIP 配置。
type ISPSpeedTestConfig struct {
	Colo           string `json:"colo,omitempty"`            // 地区码，逗号分隔，如 "HKG,NRT"
	Threads        int    `json:"threads,omitempty"`         // 线程数（下限保护 >=1）
	DisableDownload bool  `json:"disable_download,omitempty"` // 关闭下载测速
	IPFile         string `json:"ip_file,omitempty"`         // 指定 IP 数据文件（覆盖全局默认拉取）
}

// ISPConf 单运营商线路配置（多运营商分流 mode=isp_lines 时使用）。
type ISPConf struct {
	Domains  []string `json:"domains"`
	IPSource struct {
		// Files: key=运营商(默认/联通/移动/电信) → IP 文件路径（.iplist/.csv/.txt）。
		Files map[string]string `json:"files"`
	} `json:"ip_source"`
	// SpeedTest 该线路独立测速参数（可选；缺省时回退全局 CFIP 测速配置）。
	SpeedTest *ISPSpeedTestConfig `json:"speed_test,omitempty"`
}

// DNSPodConfig DNSPod DNS 同步配置。
// Mode: "single" 单线路 | "isp_lines" 多运营商分流（与现有模板 dns.mode 对齐）。
type DNSPodConfig struct {
	Enabled   bool               `json:"enabled"`
	SecretID  string             `json:"secret_id"`
	SecretKey string             `json:"secret_key"`
	Mode      string             `json:"mode"`
	ISP       map[string]ISPConf `json:"isp_lines"` // key=线路名(默认/联通/移动/电信)

	// 单线路兼容字段（mode=single 时使用）
	Domain           string            `json:"domain"`
	TTL              int               `json:"ttl"`
	MaxIPsPerRecord  int               `json:"max_ips_per_record"`
	SubDomain        string            `json:"sub_domain"`
	SubDomainUnified string            `json:"sub_domain_unified"`
	// SubDomainUnifiedMode 统一子域取 IP 的模式："first_line"（默认，取 DefaultLine/首线路 IP）| "global_best"（取全局最优 IP 文件首行）。
	SubDomainUnifiedMode string `json:"sub_domain_unified_mode,omitempty"`
	// UnifiedGlobalBestFile 统一子域 global_best 模式读取的全局最优 IP 文件（空则归一到 DefaultGlobalBestIPFile）。
	UnifiedGlobalBestFile string `json:"unified_global_best_file,omitempty"`
	SubDomains       map[string]string `json:"sub_domains"` // 线路名 → 子域名
	IPFilePath       string            `json:"ip_file"`
	LogDir           string            `json:"log_dir"`
	Timeout          int               `json:"timeout"`
	MaxRetries       int               `json:"max_retries"`

	// 多线路增强字段（mode=isp_lines 时使用）
	DefaultLine    string            `json:"default_line,omitempty"`    // 统一子域取该线路 IP；空则取首线路
	TTLByLine      map[string]int    `json:"ttl_by_line,omitempty"`     // 线路名 → TTL 覆盖
	DeleteMode     string            `json:"delete_mode,omitempty"`     // none|unified|unified-non-default，空→none
	SpeedTestPerISP bool             `json:"speed_test_per_isp,omitempty"` // 是否按线路独立测速
}

// Config 聚合全部配置。
// 顶层字段统一使用 snake_case 标签，与 IPC（Rust/Svelte 端）约定一致；
// 缺标签时 Go 序列化会回退为 PascalCase，故此处显式固定为小写。
type Config struct {
	Global *GlobalConfig                    `json:"global,omitempty"`
	CFIP   *CFIPConfig                      `json:"cf_ip,omitempty"`
	CFDNS  *CFDNSConfig                     `json:"cf_dns,omitempty"`
	DNSPod *DNSPodConfig                    `json:"dnspod,omitempty"`
	// DNSPodDomains 多域名配置：key=域名（默认取文件名去 .conf，文件内 domain 非空以其为准），
	// 值同单值 DNSPodConfig 结构（仍走 isp_lines 多线路）。Domains 非空时 registry 遍历各域名（Enabled 过滤），
	// 否则回退单值 DNSPod。
	DNSPodDomains map[string]*DNSPodConfig `json:"dnspod_domains,omitempty"`
	// CFDNSDomains 多域名配置：结构与 DNSPodDomains 同理（单值 CFDNS）。
	CFDNSDomains map[string]*CFDNSConfig `json:"cf_dns_domains,omitempty"`
	// Modules 扩展钩子：各外部 DNS 提供方（如 aliyun）的自有配置。
	// 由 loadDir 从 modules.json 增量读取填充；config 包不感知具体 provider 结构
	// （因 config 严禁 import internal/dns，新 provider 的校验下沉到模块自身）。
	Modules map[string]json.RawMessage `json:"modules,omitempty"`
}
