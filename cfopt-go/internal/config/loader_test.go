package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

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
