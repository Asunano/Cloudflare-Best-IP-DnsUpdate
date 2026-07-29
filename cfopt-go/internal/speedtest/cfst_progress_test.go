package speedtest

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// TestCFSTRun_ProgressCallbackInvoked 验证：cfst 输出 "X / Y" 进度时，
// Run 通过 progress 回调上报（stage="speedtest" 且最终 cur==total）。
// 用一个临时假二进制（模拟 cfst）向 stdout 打印带 \r 的进度并写出合法 CSV。
func TestCFSTRun_ProgressCallbackInvoked(t *testing.T) {
	dir := t.TempDir()

	var binPath string
	if runtime.GOOS == "windows" {
		binPath = filepath.Join(dir, "cfst-fake.bat")
		// %2 为 -o 后的输出路径；打印进度并写合法 CSV 后退出 0。
		content := "@echo off\r\n" +
			"echo 1 / 5^r2 / 5^r3 / 5^r4 / 5^r5 / 5\r\n" +
			"echo IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码>%2\r\n" +
			"echo 1.2.3.4,4,4,0,10,100,HKG>>%2\r\n" +
			"exit /b 0\r\n"
		require.NoError(t, os.WriteFile(binPath, []byte(content), 0o644))
	} else {
		binPath = filepath.Join(dir, "cfst-fake.sh")
		content := "#!/bin/sh\n" +
			"printf '1 / 5\\r2 / 5\\r3 / 5\\r4 / 5\\r5 / 5\\n'\n" +
			"printf 'IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码\\n1.2.3.4,4,4,0,10,100,HKG\\n' > \"$2\"\n" +
			"exit 0\n"
		require.NoError(t, os.WriteFile(binPath, []byte(content), 0o755))
	}

	// 预置 ip.txt 命中本地缓存分支，避免回退外网拉取。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "ip.txt"), []byte("203.0.113.0/24\n"), 0o644))

	tester := &CFSTTester{binPath: binPath}
	cfg := &config.CFIPConfig{Paths: config.PathConfig{OutputDir: dir}}

	var lastCur, lastTotal int
	var seenStage string
	results, err := tester.Run(context.Background(), cfg, func(stage string, cur, total int) {
		seenStage = stage
		lastCur = cur
		lastTotal = total
	})
	require.NoError(t, err, "假 cfst 退出 0 应成功")
	require.Len(t, results, 1, "应解析出 1 条结果")

	// 最终应收到 cur==total==5 的进度（末次覆盖），且阶段为 speedtest。
	assert.Equal(t, "speedtest", seenStage)
	assert.Equal(t, 5, lastTotal)
	assert.Equal(t, 5, lastCur)
}
