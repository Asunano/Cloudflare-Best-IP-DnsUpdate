package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestLoadFresh_DomainJSON 验证多域名配置兼容 .json 扩展名（Bash 版遗留配置）。
func TestLoadFresh_DomainJSON(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "dnspod"), 0o755))
	writeFiles(t, dir, map[string]string{
		"global.json": `{}`,
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
		"dnspod/example.com.json": `{"enabled":true,"domain":"example.com","mode":"single","secret_id":"sid","secret_key":"sk","ip_file":"./a.iplist"}`,
	})
	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	d, ok := cfg.DNSPodDomains["example.com"]
	require.True(t, ok, "应能从 .json 域名配置加载")
	require.NotNil(t, d)
	assert.Equal(t, "example.com", d.Domain)
}

// TestLoadFresh_DomainConfPriority 验证同 stem 同时存在 .conf 与 .json 时优先 .conf。
func TestLoadFresh_DomainConfPriority(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "dnspod"), 0o755))
	writeFiles(t, dir, map[string]string{
		"global.json": `{}`,
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
		"dnspod/same.conf": `{"enabled":true,"domain":"from-conf","mode":"single","secret_id":"a","secret_key":"b","ip_file":"./a.iplist"}`,
		"dnspod/same.json": `{"enabled":true,"domain":"from-json","mode":"single","secret_id":"a","secret_key":"b","ip_file":"./a.iplist"}`,
	})
	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	_, okConf := cfg.DNSPodDomains["from-conf"]
	_, okJSON := cfg.DNSPodDomains["from-json"]
	assert.True(t, okConf, ".conf 应胜出")
	assert.False(t, okJSON, ".json 应被 .conf 覆盖")
}

// TestLoadFresh_DomainCFJSON 验证 cf-dns 多域名 .json 也被扫描加载。
func TestLoadFresh_DomainCFJSON(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "cf-dns"), 0o755))
	writeFiles(t, dir, map[string]string{
		"global.json": `{}`,
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
		"cf-dns/example.org.json": `{"enabled":true,"api":{"token":"t","zone_id":"z"},"dns":{"record_name":"@","domain":"example.org"},"ip_source":{"file_path":"./a.iplist"}}`,
	})
	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	d, ok := cfg.CFDNSDomains["example.org"]
	require.True(t, ok, "应能从 .json 加载 CF 多域名配置")
	assert.Equal(t, "example.org", d.DNS.Domain)
}

// writeFiles 将多个配置文件写入临时目录（自动创建父目录），返回目录路径。
func writeFiles(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		p := filepath.Join(dir, name)
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
		require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	}
}

// writeConf 将多个配置文件写入临时目录，返回目录路径。
func writeConf(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644))
	}
	return dir
}

// TestLoadFresh_Defaults 验证加载空配置后合理默认值生效。
func TestLoadFresh_Defaults(t *testing.T) {
	dir := writeConf(t, map[string]string{
		"global.json": `{}`,
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
	})

	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	require.NotNil(t, cfg)

	// global 默认值
	assert.Equal(t, "INFO", cfg.Global.LogLevel)
	assert.Equal(t, "./logs", cfg.Global.LogDir)
	assert.Equal(t, "./locks", cfg.Global.LockDir)
	assert.Equal(t, "./assets/data", cfg.Global.DataDir)

	// cf-ip 默认值
	require.NotNil(t, cfg.CFIP)
	assert.Equal(t, 200, cfg.CFIP.CFST.Threads)
	assert.Equal(t, "./assets/cfst", cfg.CFIP.CFST.Directory)
	assert.Equal(t, 5, cfg.CFIP.SpeedTest.TakeIPNum)
	assert.Equal(t, 3, cfg.CFIP.SpeedTest.MaxRetry)
	assert.Equal(t, "./assets/data/cf-ip", cfg.CFIP.Paths.OutputDir)

	// cf-dns 默认值
	require.NotNil(t, cfg.CFDNS)
	assert.Equal(t, 10, cfg.CFDNS.API.Timeout)
	assert.Equal(t, 5, cfg.CFDNS.API.MaxRetries)
	assert.Equal(t, 2, cfg.CFDNS.DNS.MaxIPsPerRecord)
	assert.Equal(t, "./assets/data/cf-dns/ip_list.iplist", cfg.CFDNS.IPSource.FilePath)

	// dnspod 默认值
	require.NotNil(t, cfg.DNSPod)
	assert.Equal(t, 600, cfg.DNSPod.TTL)
	assert.Equal(t, 2, cfg.DNSPod.MaxIPsPerRecord)
	assert.Equal(t, 10, cfg.DNSPod.Timeout)
	assert.Equal(t, 5, cfg.DNSPod.MaxRetries)
}

// TestLoadFresh_ValidAllEnabled 验证完整启用配置可被正确解析且通过 schema 校验。
func TestLoadFresh_ValidAllEnabled(t *testing.T) {
	dir := writeConf(t, map[string]string{
		"global.json": `{"log_level":"DEBUG"}`,
		"cf-ip.json":  `{"enabled":true,"cfst":{"threads":50,"port":443},"speed_test":{"take_ip_num":3,"max_retry":2}}`,
		"cf-dns.json": `{"enabled":true,"api":{"token":"tok","zone_id":"zid"},"dns":{"record_name":"dns","domain":"example.com","max_ips_per_record":2}}`,
		"dnspod.json": `{"enabled":true,"secret_id":"sid","secret_key":"sk","mode":"single","domain":"example.com"}`,
	})

	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	require.NotNil(t, cfg)

	assert.Equal(t, "DEBUG", cfg.Global.LogLevel)
	require.NotNil(t, cfg.CFIP)
	assert.True(t, cfg.CFIP.Enabled)
	assert.Equal(t, 50, cfg.CFIP.CFST.Threads)
	require.NotNil(t, cfg.CFDNS)
	assert.True(t, cfg.CFDNS.Enabled)
	assert.Equal(t, "tok", cfg.CFDNS.API.Token)
	require.NotNil(t, cfg.DNSPod)
	assert.True(t, cfg.DNSPod.Enabled)
	assert.Equal(t, "single", cfg.DNSPod.Mode)
}

// TestLoadFresh_SchemaErrors 验证 schema 校验对非法配置返回结构化错误。
func TestLoadFresh_SchemaErrors(t *testing.T) {
	t.Run("cf-dns启用但token为空", func(t *testing.T) {
		dir := writeConf(t, map[string]string{
			"global.json": `{}`,
			"cf-ip.json":  `{}`,
			"cf-dns.json": `{"enabled":true,"api":{"zone_id":"zid"},"dns":{"domain":"x"}}`,
			"dnspod.json": `{}`,
		})
		_, err := LoadFresh(dir)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "token")
	})

	t.Run("dnspod启用isp_lines但缺isp_lines", func(t *testing.T) {
		dir := writeConf(t, map[string]string{
			"global.json": `{}`,
			"cf-ip.json":  `{}`,
			"cf-dns.json": `{}`,
			"dnspod.json": `{"enabled":true,"secret_id":"s","secret_key":"k","mode":"isp_lines","domain":"x"}`,
		})
		_, err := LoadFresh(dir)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "isp_lines")
	})

	t.Run("log_level非法", func(t *testing.T) {
		dir := writeConf(t, map[string]string{
			"global.json": `{"log_level":"TRACE"}`,
			"cf-ip.json":  `{}`,
			"cf-dns.json": `{}`,
			"dnspod.json": `{}`,
		})
		_, err := LoadFresh(dir)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "log_level")
	})

	t.Run("cf-ip线程数超范围", func(t *testing.T) {
		dir := writeConf(t, map[string]string{
			"global.json": `{}`,
			"cf-ip.json":  `{"enabled":true,"cfst":{"threads":2000}}`,
			"cf-dns.json": `{}`,
			"dnspod.json": `{}`,
		})
		_, err := LoadFresh(dir)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "threads")
	})
}

// TestLoadFresh_MissingFile 验证缺失配置文件时返回 error。
func TestLoadFresh_MissingFile(t *testing.T) {
	// 仅写入 cf-ip.json，缺失 global.json 等
	dir := writeConf(t, map[string]string{
		"cf-ip.json": `{}`,
	})
	_, err := LoadFresh(dir)
	require.Error(t, err, "缺失配置文件应返回错误")
}

// TestLoadFresh_BadJSON 验证 JSON 语法错误时返回 error。
func TestLoadFresh_BadJSON(t *testing.T) {
	dir := writeConf(t, map[string]string{
		"global.json": `{ "log_level": }`, // 非法 JSON
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
	})
	_, err := LoadFresh(dir)
	require.Error(t, err, "非法 JSON 应返回错误")
}

// TestConfigSerialization_SnakeCaseKeys 验证 Config 经 IPC 序列化后顶层键为 snake_case，
// 即 global / cf_ip / cf_dns / dnspod（不再出现 PascalCase 顶层键）。
func TestConfigSerialization_SnakeCaseKeys(t *testing.T) {
	dir := writeConf(t, map[string]string{
		"global.json": `{"log_level":"DEBUG"}`,
		"cf-ip.json":  `{"enabled":true}`,
		"cf-dns.json": `{"enabled":true,"api":{"token":"t","zone_id":"z"},"dns":{"domain":"x"}}`,
		"dnspod.json": `{"enabled":true,"secret_id":"s","secret_key":"k","domain":"x"}`,
	})
	cfg, err := LoadFresh(dir)
	require.NoError(t, err)

	b, err := json.Marshal(cfg)
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &m))

	// 期望的 snake_case 顶层键均存在。
	for _, k := range []string{"global", "cf_ip", "cf_dns", "dnspod"} {
		_, ok := m[k]
		assert.Truef(t, ok, "缺少 snake_case 顶层键 %q", k)
	}
	// 不应出现 PascalCase 顶层键。
	for _, k := range []string{"Global", "CFIP", "CFDNS", "DNSPod"} {
		_, ok := m[k]
		assert.Falsef(t, ok, "不应出现 PascalCase 顶层键 %q", k)
	}
}

// TestLoadModulesJSON 验证 loadDir 增量读取 modules.json 并正确填充 Config.Modules。
func TestLoadModulesJSON(t *testing.T) {
	dir := writeConf(t, map[string]string{
		"global.json": `{}`,
		"cf-ip.json":  `{}`,
		"cf-dns.json": `{}`,
		"dnspod.json": `{}`,
		"modules.json": `{"aliyun":{"access_key":"ak","region":"cn-hangzhou"},"foo":{"x":1}}`,
	})
	cfg, err := LoadFresh(dir)
	require.NoError(t, err)

	require.NotNil(t, cfg.Modules, "Config.Modules 不应为 nil")
	assert.Len(t, cfg.Modules, 2)
	_, ok := cfg.Modules["aliyun"]
	assert.True(t, ok, "应包含 aliyun 模块配置")
	_, ok = cfg.Modules["foo"]
	assert.True(t, ok, "应包含 foo 模块配置")

	// 序列化后顶层应出现 modules 键。
	b, err := json.Marshal(cfg)
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &m))
	_, ok = m["modules"]
	assert.True(t, ok, "序列化结果应含 modules 顶层键")
}

// TestLoadFresh_MultiDomainConf 验证多域名 .conf 加载：key 取文件名、domain 字段可覆盖、与单值共存。
// 为避免源码中文 key 的编码脆弱性，此处使用 ASCII 线路名。
func TestLoadFresh_MultiDomainConf(t *testing.T) {
	dir := t.TempDir()
	// 四个基础文件（单值，enabled 均空）。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "global.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-ip.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-dns.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod.json"), []byte(`{}`), 0o644))

	require.NoError(t, os.MkdirAll(filepath.Join(dir, "dnspod"), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "cf-dns"), 0o755))

	// DNSPod 多域名：文件名 example.com.conf，domain 字段为空 → key=example.com。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod", "example.com.conf"),
		[]byte(`{"enabled":true,"domain":"example.com","mode":"single","ip_file":"./assets/data/dnspod-dns/example.com/ip.txt"}`), 0o644))
	// 文件名 foo.conf，但 domain=bar.com → key 应被覆盖为 bar.com。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod", "foo.conf"),
		[]byte(`{"enabled":true,"domain":"bar.com","mode":"single","ip_file":"./a/b.txt"}`), 0o644))
	// CFDNS 多域名。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-dns", "example.org.conf"),
		[]byte(`{"enabled":true,"api":{"token":"t","zone_id":"z"},"dns":{"domain":"example.org"},"ip_source":{"file_path":"./assets/data/cf-dns/example.org/ip.txt"}}`), 0o644))

	cfg, err := LoadFresh(dir)
	require.NoError(t, err)

	// 单值与多域名共存。
	require.NotNil(t, cfg.DNSPod)
	require.NotNil(t, cfg.CFDNS)

	// DNSPod 多域名 key 取自文件名。
	require.Contains(t, cfg.DNSPodDomains, "example.com")
	// domain 字段覆盖 key。
	require.Contains(t, cfg.DNSPodDomains, "bar.com")
	require.NotContains(t, cfg.DNSPodDomains, "foo", "domain 字段应覆盖文件名为 key")
	// CFDNS 多域名。
	require.Contains(t, cfg.CFDNSDomains, "example.org")

	// 输出型路径规整为 .iplist。
	assert.Equal(t, "./assets/data/dnspod-dns/example.com/ip.iplist", cfg.DNSPodDomains["example.com"].IPFilePath)
	assert.Equal(t, "./a/b.iplist", cfg.DNSPodDomains["bar.com"].IPFilePath)
	assert.Equal(t, "./assets/data/cf-dns/example.org/ip.iplist", cfg.CFDNSDomains["example.org"].IPSource.FilePath)

	// UnifiedGlobalBestFile 默认值归一。
	assert.Equal(t, DefaultGlobalBestIPFile, cfg.DNSPodDomains["example.com"].UnifiedGlobalBestFile)
}

// TestLoadFresh_IPListNormalization 验证：输出型 IP 源路径规整为 .iplist，
// 但输入型 speed_test.ip_file（cfst -f）保持不变。
// 为避免手写 JSON 字面量引入不可见字符，此处用结构体经 json.Marshal 生成配置。
func TestLoadFresh_IPListNormalization(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "global.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-ip.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-dns.json"), []byte(`{}`), 0o644))

	// 构造 DNSPod 配置（含 isp_lines 多线路），经 json.Marshal 落盘，避免手写 JSON 编码问题。
	type ipSrc struct {
		Files map[string]string `json:"files"`
	}
	dp := DNSPodConfig{
		Enabled:    true,
		SecretID:   "s",
		SecretKey:  "k",
		Domain:     "x",
		Mode:       "isp_lines",
		IPFilePath: "./single.txt",
		ISP: map[string]ISPConf{
			"default_line": {
				IPSource: ipSrc{Files: map[string]string{"default": "./x/default.txt"}},
			},
			"unicom": {
				IPSource:  ipSrc{Files: map[string]string{"unicom": "./x/unicom.txt"}},
				SpeedTest: &ISPSpeedTestConfig{Colo: "HKG", IPFile: "./x/unicom.ip.txt"},
			},
		},
	}
	dpJSON, err := json.Marshal(dp)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod.json"), dpJSON, 0o644))

	cfg, err := LoadFresh(dir)
	require.NoError(t, err)

	// 输出型：单线路 ip_file 与各 isp ip_source.files 均改写为 .iplist。
	assert.Equal(t, "./single.iplist", cfg.DNSPod.IPFilePath, "单线路输出 ip_file 应改写 .iplist")
	assert.Equal(t, "./x/default.iplist", cfg.DNSPod.ISP["default_line"].IPSource.Files["default"])
	assert.Equal(t, "./x/unicom.iplist", cfg.DNSPod.ISP["unicom"].IPSource.Files["unicom"])
	// 输入型：speed_test.ip_file（cfst -f）保持不变。
	assert.Equal(t, "./x/unicom.ip.txt", cfg.DNSPod.ISP["unicom"].SpeedTest.IPFile, "输入型 speed_test.ip_file 不应被改写")

	// GlobalBestFile 默认值归一。
	assert.Equal(t, DefaultGlobalBestIPFile, cfg.CFIP.Paths.GlobalBestFile)
}

// TestLoadFresh_ConfExampleNotLoaded 验证 .conf.example 等模板不会被当作多域名配置加载。
func TestLoadFresh_ConfExampleNotLoaded(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "global.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-ip.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "cf-dns.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod.json"), []byte(`{}`), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "dnspod"), 0o755))
	// 模板文件（扩展名非 .conf）应被忽略。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "dnspod", "example.com.conf.example"),
		[]byte(`{"enabled":true,"domain":"example.com"}`), 0o644))

	cfg, err := LoadFresh(dir)
	require.NoError(t, err)
	assert.Empty(t, cfg.DNSPodDomains, ".conf.example 模板不应被加载")
}
