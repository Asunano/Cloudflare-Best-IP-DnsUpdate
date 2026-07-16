// Package config 定义 cfopt 的配置模型与加载/校验逻辑。
// 配置结构字段与 conf/*.example 示例 JSON 严格对齐（见各结构体 json tag）。
package config

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
}

// CFIPConfig Cloudflare IP 优选配置。
type CFIPConfig struct {
	Enabled   bool            `json:"enabled"`
	CFST      CFSTConfig      `json:"cfst"`
	SpeedTest SpeedTestConfig `json:"speed_test"`
	Paths     PathConfig      `json:"paths"`
	// CFSTPath 可选：显式覆盖 cfst 二进制路径，优先级高于 assets/cfst/<goos>-<goarch> 探测。
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

// ISPConf 单运营商线路配置（多运营商分流 mode=isp_lines 时使用）。
type ISPConf struct {
	Domains  []string `json:"domains"`
	IPSource struct {
		// Files: key=运营商(默认/联通/移动/电信) → IP 文件路径（.iplist/.csv/.txt）。
		Files map[string]string `json:"files"`
	} `json:"ip_source"`
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
	SubDomains       map[string]string `json:"sub_domains"` // 线路名 → 子域名
	IPFilePath       string            `json:"ip_file"`
	LogDir           string            `json:"log_dir"`
	Timeout          int               `json:"timeout"`
	MaxRetries       int               `json:"max_retries"`
}

// Config 聚合全部配置。
type Config struct {
	Global *GlobalConfig
	CFIP   *CFIPConfig
	CFDNS  *CFDNSConfig
	DNSPod *DNSPodConfig
}
