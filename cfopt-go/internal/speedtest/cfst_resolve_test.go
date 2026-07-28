package speedtest

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// TestResolveCFSTBinary_Level4MatchesFetchedBinary 验证端到端一致性（需求 #3 + #4）：
// `cfopt cfst fetch` 把二进制安装到 assets/cfst/cfst[.exe]（见 internal/cfst/fetch.go 的
// DefaultCFSTDestDir 与 binName），`resolveCFSTBinary` 第 4 级探测必须能找到它。
//
// 即：设置 cfg.CFST.Directory = dir（模拟默认 ./assets/cfst），并在 dir 下放置 fetch 实际
// 安装的二进制名 cfst[.exe]，resolveCFSTBinary 必须返回该路径。
//
// 若实现错误地探测 cfst-<goos>-<goarch>[.exe]（如 cfst-windows-amd64.exe），
// 则 fetch 安装名（cfst.exe）与探测名（cfst-windows-amd64.exe）不匹配，
// 默认 `cfst fetch` → `sync` 流程将找不到二进制而报错。此测试锁定正确行为。
func TestResolveCFSTBinary_Level4MatchesFetchedBinary(t *testing.T) {
	dir := t.TempDir()

	// fetch 实际安装的二进制名（与 cfst/fetch.go 一致）。
	base := "cfst"
	if runtime.GOOS == "windows" {
		base = "cfst.exe"
	}
	fetched := filepath.Join(dir, base)
	require.NoError(t, os.WriteFile(fetched, []byte("bin"), 0o755))

	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Directory: dir}}

	got := resolveCFSTBinary(cfg)
	assert.Equal(t, fetched, got,
		"resolveCFSTBinary 第4级应找到 fetch 安装的二进制 %s，而非 cfst-<os>-<arch>[.exe]", fetched)

	// 端到端：NewCFSTTester 应能成功解析（不报“二进制不存在”）。
	_, err := NewCFSTTester(cfg)
	require.NoError(t, err, "`cfst fetch` 安装后 `cfopt sync` 必须能解析到 cfst 二进制")
}
