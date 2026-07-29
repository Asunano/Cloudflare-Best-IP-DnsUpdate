package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"cfopt/internal/common"
)

var (
	loadOnce sync.Once
	cached   *Config
	loadErr  error
)

// Load 从 dir 目录加载 global.json / cf-ip.json / cf-dns.json / dnspod.json，
// 使用 sync.Once 缓存首次结果（对应原 Bash 的 CF_IP_CFG_LOADED 单例语义）。
// 后续调用忽略 dir 参数，返回首次缓存结果。
func Load(dir string) (*Config, error) {
	loadOnce.Do(func() {
		cfg, err := loadDir(dir)
		if err != nil {
			loadErr = err
			return
		}
		if err := validateConfigSchema(cfg); err != nil {
			loadErr = err
			return
		}
		cached = cfg
	})
	return cached, loadErr
}

// LoadFresh 不使用缓存，强制从 dir 重新加载并校验（供测试/热加载使用）。
func LoadFresh(dir string) (*Config, error) {
	cfg, err := loadDir(dir)
	if err != nil {
		return nil, err
	}
	if err := validateConfigSchema(cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

// loadDir 读取并解析四个配置文件。
func loadDir(dir string) (*Config, error) {
	cfg := &Config{}
	var err error
	if cfg.Global, err = readJSON[GlobalConfig](filepath.Join(dir, "global.json")); err != nil {
		return nil, common.Wrap("config:load global.json", err)
	}
	if cfg.CFIP, err = readJSON[CFIPConfig](filepath.Join(dir, "cf-ip.json")); err != nil {
		return nil, common.Wrap("config:load cf-ip.json", err)
	}
	if cfg.CFDNS, err = readJSON[CFDNSConfig](filepath.Join(dir, "cf-dns.json")); err != nil {
		return nil, common.Wrap("config:load cf-dns.json", err)
	}
	if cfg.DNSPod, err = readJSON[DNSPodConfig](filepath.Join(dir, "dnspod.json")); err != nil {
		return nil, common.Wrap("config:load dnspod.json", err)
	}

	// 多域名：扫描 conf/dnspod/* 与 conf/cf-dns/*（JSON 内容、扩展名 .conf 或 .json，.conf 优先），
	// key 默认取文件名去扩展名，文件内 domain 字段非空以其为准。与单值 dnspod.json/cf-dns.json 共存。
	// 兼容 Bash 版多域名 *.json 配置（无需手动改名即可被识别，亦可用 `cfopt config migrate` 迁移）。
	cfg.DNSPodDomains = scanDNSPodConfDir(dir)
	cfg.CFDNSDomains = scanCFDNSConfDir(dir)

	// T-D：增量读取 modules.json（扩展钩子），additive，完全不触碰 cf/dnspod 分支。
	// 文件不存在时跳过（可选）；其余错误（如 JSON 语法错误）向上返回。
	if raw, mErr := os.ReadFile(filepath.Join(dir, "modules.json")); mErr == nil {
		var mods map[string]json.RawMessage
		if uErr := json.Unmarshal(raw, &mods); uErr != nil {
			return nil, common.Wrap("config:load modules.json", uErr)
		}
		cfg.Modules = mods
	} else if !os.IsNotExist(mErr) {
		return nil, common.Wrap("config:load modules.json", mErr)
	}

	applyDefaults(cfg)
	return cfg, nil
}

// scanDomainConfBytes 扫描 dir/<subdir> 下所有 *.conf 与 *.json（JSON 内容），以文件名去扩展名为 key
// 返回各 stem 选中的文件字节。同 stem 同时存在 .conf 与 .json 时优先 .conf（其余场景后者覆盖前者，
// 保证 .conf 始终胜出，与迁移场景兼容）。目录缺失/读取失败则跳过该文件。
// 注意：仅匹配 .conf / .json 扩展名，.conf.example 等模板不会被加载。
func scanDomainConfBytes(dir, subdir string) map[string][]byte {
	out := make(map[string][]byte)
	entries, err := os.ReadDir(filepath.Join(dir, subdir))
	if err != nil {
		return out // 目录缺失（可选）则视为无多域名配置
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		var stem string
		switch {
		case strings.HasSuffix(name, ".conf"):
			stem = strings.TrimSuffix(name, ".conf")
		case strings.HasSuffix(name, ".json"):
			stem = strings.TrimSuffix(name, ".json")
		default:
			continue
		}
		data, rerr := os.ReadFile(filepath.Join(dir, subdir, name))
		if rerr != nil {
			continue
		}
		// .conf 优先：若已写入（来自 .json 或 .conf），仅当本次为 .conf 时才覆盖。
		if _, exists := out[stem]; exists && !strings.HasSuffix(name, ".conf") {
			continue
		}
		out[stem] = data
	}
	return out
}

// scanDNSPodConfDir 扫描 dir/dnspod 下所有 *.conf 与 *.json（JSON 内容），返回 map[域名]*DNSPodConfig。
// key 取文件名去扩展名；若文件内 domain 字段非空，以其为准。与 Bash 多域名 *.json 配置向后兼容。
func scanDNSPodConfDir(dir string) map[string]*DNSPodConfig {
	out := make(map[string]*DNSPodConfig)
	for stem, data := range scanDomainConfBytes(dir, "dnspod") {
		var v DNSPodConfig
		if jerr := json.Unmarshal(data, &v); jerr != nil {
			continue
		}
		key := stem
		if strings.TrimSpace(v.Domain) != "" {
			key = v.Domain
		}
		out[key] = &v
	}
	return out
}

// scanCFDNSConfDir 扫描 dir/cf-dns 下所有 *.conf 与 *.json（JSON 内容），返回 map[域名]*CFDNSConfig。
// 规则同 scanDNSPodConfDir（key 取文件名，文件内 dns.domain 非空以其为准）。
func scanCFDNSConfDir(dir string) map[string]*CFDNSConfig {
	out := make(map[string]*CFDNSConfig)
	for stem, data := range scanDomainConfBytes(dir, "cf-dns") {
		var v CFDNSConfig
		if jerr := json.Unmarshal(data, &v); jerr != nil {
			continue
		}
		key := stem
		if strings.TrimSpace(v.DNS.Domain) != "" {
			key = v.DNS.Domain
		}
		out[key] = &v
	}
	return out
}

// readJSON 泛型读取并解析 JSON 文件为 T。
func readJSON[T any](path string) (*T, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var v T
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, err
	}
	return &v, nil
}

// applyDefaults 为零值字段填充合理默认值（与原 Bash 默认行为一致）。
func applyDefaults(cfg *Config) {
	if cfg.Global == nil {
		cfg.Global = &GlobalConfig{}
	}
	if cfg.Global.LogLevel == "" {
		cfg.Global.LogLevel = "INFO"
	}
	if cfg.Global.LogDir == "" {
		cfg.Global.LogDir = "./logs"
	}
	if cfg.Global.LockDir == "" {
		cfg.Global.LockDir = "./locks"
	}
	if cfg.Global.DataDir == "" {
		cfg.Global.DataDir = "./assets/data"
	}

	if cfg.CFIP != nil {
		if cfg.CFIP.CFST.Threads == 0 {
			cfg.CFIP.CFST.Threads = 200
		}
		if cfg.CFIP.CFST.Directory == "" {
			cfg.CFIP.CFST.Directory = "./assets/cfst"
		}
		if cfg.CFIP.SpeedTest.TakeIPNum == 0 {
			cfg.CFIP.SpeedTest.TakeIPNum = 5
		}
		if cfg.CFIP.SpeedTest.MaxRetry == 0 {
			cfg.CFIP.SpeedTest.MaxRetry = 3
		}
		if cfg.CFIP.Paths.OutputDir == "" {
			cfg.CFIP.Paths.OutputDir = "./assets/data/cf-ip"
		}
	}

	if cfg.CFDNS != nil {
		if cfg.CFDNS.API.Timeout == 0 {
			cfg.CFDNS.API.Timeout = 10
		}
		if cfg.CFDNS.API.MaxRetries == 0 {
			cfg.CFDNS.API.MaxRetries = 5
		}
		if cfg.CFDNS.DNS.MaxIPsPerRecord == 0 {
			cfg.CFDNS.DNS.MaxIPsPerRecord = 2
		}
		if cfg.CFDNS.IPSource.FilePath == "" {
			cfg.CFDNS.IPSource.FilePath = "./assets/data/cf-dns/ip_list.iplist"
		}
		// 输出型 IP 源路径规整为 .iplist（防 .txt 误解析）；不动 speed_test.ip_file。
		cfg.CFDNS.IPSource.FilePath = normalizeIPListExt(cfg.CFDNS.IPSource.FilePath)
	}

	if cfg.DNSPod != nil {
		if cfg.DNSPod.TTL == 0 {
			cfg.DNSPod.TTL = 600
		}
		if cfg.DNSPod.MaxIPsPerRecord == 0 {
			cfg.DNSPod.MaxIPsPerRecord = 2
		}
		if cfg.DNSPod.Timeout == 0 {
			cfg.DNSPod.Timeout = 10
		}
		if cfg.DNSPod.MaxRetries == 0 {
			cfg.DNSPod.MaxRetries = 5
		}
		// 输出型 IP 源路径规整为 .iplist。
		cfg.DNSPod.IPFilePath = normalizeIPListExt(cfg.DNSPod.IPFilePath)
		for k, isp := range cfg.DNSPod.ISP {
			for fk, f := range isp.IPSource.Files {
				isp.IPSource.Files[fk] = normalizeIPListExt(f)
			}
			cfg.DNSPod.ISP[k] = isp
		}
		// 统一子域 global_best 文件默认值归一（空则 DefaultGlobalBestIPFile）。
		if cfg.DNSPod.UnifiedGlobalBestFile == "" {
			cfg.DNSPod.UnifiedGlobalBestFile = DefaultGlobalBestIPFile
		}
	}

	// 多域名 DNSPod：逐域规整输出型路径（IPFilePath + 各 isp ip_source.files）+ 统一子域默认值。
	for _, d := range cfg.DNSPodDomains {
		if d == nil {
			continue
		}
		d.IPFilePath = normalizeIPListExt(d.IPFilePath)
		for k, isp := range d.ISP {
			for fk, f := range isp.IPSource.Files {
				isp.IPSource.Files[fk] = normalizeIPListExt(f)
			}
			d.ISP[k] = isp
		}
		if d.UnifiedGlobalBestFile == "" {
			d.UnifiedGlobalBestFile = DefaultGlobalBestIPFile
		}
	}

	// 多域名 CFDNS：逐域规整输出型路径。
	for _, d := range cfg.CFDNSDomains {
		if d == nil {
			continue
		}
		d.IPSource.FilePath = normalizeIPListExt(d.IPSource.FilePath)
	}

	if cfg.CFIP != nil {
		// 全局最优 IP 文件路径默认值归一（空则 DefaultGlobalBestIPFile）。
		if cfg.CFIP.Paths.GlobalBestFile == "" {
			cfg.CFIP.Paths.GlobalBestFile = DefaultGlobalBestIPFile
		}
	}
}

// normalizeIPListExt 将输出型 IP 源路径规整为 .iplist 扩展名（仅改写扩展名，保留目录与基名）。
// 空串原样返回；已是 .iplist 原样返回；其余（.txt/.csv 等）替换为 .iplist。
// 注意：仅供输出型路径使用，输入型 speed_test.ip_file 不应调用本函数。
func normalizeIPListExt(p string) string {
	if p == "" {
		return p
	}
	if filepath.Ext(p) == ".iplist" {
		return p
	}
	base := strings.TrimSuffix(p, filepath.Ext(p))
	return base + ".iplist"
}

// validateConfigSchema 做字段存在性/类型/数值范围校验，返回结构化错误。
// JSON 反序列化已保证“出现字段”的类型正确；此处补充必填项与数值范围校验。
func validateConfigSchema(cfg *Config) error {
	var errs []string

	if cfg.Global != nil {
		lvl := strings.ToUpper(cfg.Global.LogLevel)
		switch lvl {
		case "", "DEBUG", "INFO", "WARN", "WARNING", "ERROR":
		default:
			errs = append(errs, fmt.Sprintf("global.log_level 非法: %q", cfg.Global.LogLevel))
		}
	}

	if cfg.CFIP != nil && cfg.CFIP.Enabled {
		cf := cfg.CFIP.CFST
		if cf.Threads != 0 && (cf.Threads < 1 || cf.Threads > 1000) {
			errs = append(errs, fmt.Sprintf("cf-ip.cfst.threads 超出范围(1-1000): %d", cf.Threads))
		}
		if cf.Port != 0 && (cf.Port < 1 || cf.Port > 65535) {
			errs = append(errs, fmt.Sprintf("cf-ip.cfst.port 超出范围(1-65535): %d", cf.Port))
		}
		st := cfg.CFIP.SpeedTest
		if st.TakeIPNum != 0 && (st.TakeIPNum < 1 || st.TakeIPNum > 100) {
			errs = append(errs, fmt.Sprintf("cf-ip.speed_test.take_ip_num 超出范围(1-100): %d", st.TakeIPNum))
		}
		if st.MaxRetry != 0 && (st.MaxRetry < 1 || st.MaxRetry > 10) {
			errs = append(errs, fmt.Sprintf("cf-ip.speed_test.max_retry 超出范围(1-10): %d", st.MaxRetry))
		}
	}

	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		if strings.TrimSpace(cfg.CFDNS.API.Token) == "" {
			errs = append(errs, "cf-dns.api.token 不能为空")
		}
		if strings.TrimSpace(cfg.CFDNS.API.ZoneID) == "" {
			errs = append(errs, "cf-dns.api.zone_id 不能为空")
		}
		if cfg.CFDNS.DNS.MaxIPsPerRecord < 0 {
			errs = append(errs, "cf-dns.dns.max_ips_per_record 不能为负")
		}
	}

	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		if strings.TrimSpace(cfg.DNSPod.SecretID) == "" {
			errs = append(errs, "dnspod.secret_id 不能为空")
		}
		if strings.TrimSpace(cfg.DNSPod.SecretKey) == "" {
			errs = append(errs, "dnspod.secret_key 不能为空")
		}
		if strings.TrimSpace(cfg.DNSPod.Domain) == "" {
			errs = append(errs, "dnspod.domain 不能为空")
		}
		mode := strings.ToLower(cfg.DNSPod.Mode)
		if mode != "" && mode != "single" && mode != "isp_lines" {
			errs = append(errs, fmt.Sprintf("dnspod.mode 非法: %q (应为 single|isp_lines)", cfg.DNSPod.Mode))
		}
		if mode == "isp_lines" && len(cfg.DNSPod.ISP) == 0 {
			errs = append(errs, "dnspod.mode=isp_lines 但未配置 isp_lines")
		}
		// DeleteMode 校验：空视为 none；非空必须在白名单内。
		if dm := strings.TrimSpace(cfg.DNSPod.DeleteMode); dm != "" {
			switch dm {
			case "none", "unified", "unified-non-default":
			default:
				errs = append(errs, fmt.Sprintf("dnspod.delete_mode 非法: %q (应为 none|unified|unified-non-default)", cfg.DNSPod.DeleteMode))
			}
		}
		// SpeedTestPerISP 为布尔，无需范围校验；空按 false 处理（applyDefaults 已规整）。
	}

	if len(errs) > 0 {
		return common.New("config:validate", strings.Join(errs, "; "))
	}
	return nil
}

// Validate 对配置做字段存在性/类型/数值范围校验，返回结构化错误。
// 供 GUI 在保存前做前端校验，或外部调用者显式校验（内部复用 validateConfigSchema）。
func Validate(cfg *Config) error {
	if cfg == nil {
		return common.New("config:validate", "配置为空")
	}
	return validateConfigSchema(cfg)
}

// Save 将配置写回 dir 目录的四个 JSON 文件（供 GUI/热加载保存设置）。
// 写入前会应用默认值，保证产物可被 Load 正确解析。跳过为 nil 的子配置。
func Save(dir string, cfg *Config) error {
	if cfg == nil {
		return common.New("config:save", "配置为空")
	}
	applyDefaults(cfg)
	files := []struct {
		name string
		val  any
	}{
		{"global.json", cfg.Global},
		{"cf-ip.json", cfg.CFIP},
		{"cf-dns.json", cfg.CFDNS},
		{"dnspod.json", cfg.DNSPod},
	}
	for _, f := range files {
		if f.val == nil {
			continue
		}
		if err := writeJSON(filepath.Join(dir, f.name), f.val); err != nil {
			return common.Wrap("config:save:"+f.name, err)
		}
	}
	return nil
}

// writeJSON 泛型写 JSON 文件（带 2 空格缩进），失败时包装错误。
func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return common.Wrap("config:writeJSON", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return common.Wrap("config:writeJSON:"+path, err)
	}
	return nil
}
