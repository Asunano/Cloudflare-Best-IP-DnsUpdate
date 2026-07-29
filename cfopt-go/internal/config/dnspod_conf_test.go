package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestToggleDNSPodMode_ToISPLines(t *testing.T) {
	cfg := &DNSPodConfig{Domain: "example.com", SubDomain: "www", IPFilePath: "./a.iplist", Mode: "single"}
	ToggleDNSPodMode(cfg, "isp_lines")
	assert.Equal(t, "isp_lines", cfg.Mode)
	assert.Len(t, cfg.ISP, 1, "无 ISP 线路时应自动建默认线路")
	line, ok := cfg.ISP["默认"]
	assert.True(t, ok)
	assert.Equal(t, "./a.iplist", line.IPSource.Files["默认"])
}

func TestToggleDNSPodMode_ToSingle(t *testing.T) {
	cfg := &DNSPodConfig{Domain: "example.com", Mode: "isp_lines", ISP: map[string]ISPConf{"默认": {}}}
	ToggleDNSPodMode(cfg, "single")
	assert.Equal(t, "single", cfg.Mode)
	assert.Nil(t, cfg.ISP, "转 single 应清空 ISP map")
}

func TestToggleDNSPodStrategy(t *testing.T) {
	cfg := &DNSPodConfig{SubDomain: "www"}
	ToggleDNSPodStrategy(cfg, true)
	assert.Equal(t, "www", cfg.SubDomainUnified, "unified 应取当前子域")

	cfg2 := &DNSPodConfig{}
	ToggleDNSPodStrategy(cfg2, true)
	assert.Equal(t, "all", cfg2.SubDomainUnified, "子域为空时应回退 all")

	ToggleDNSPodStrategy(cfg, false)
	assert.Equal(t, "", cfg.SubDomainUnified, "separate 应清空")
}

func TestWriteDNSPodDomainConf_RejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	err := WriteDNSPodDomainConf(dir, "../evil", &DNSPodConfig{Domain: "x"})
	assert.Error(t, err, "含 .. 的域名应被拒绝")
}
