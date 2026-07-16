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

// TestCFSTRun_ReturnsStderrOnFailure 验证：当 cfst 以非 0 退出码失败时，
// Run() 必须把 cfst 的真实输出（如 stderr 报错文本）回传到错误中，
// 而不仅仅是 “exit status N”，否则用户看不到 cfst 的真实报错根因。
//
// 做法：用一个临时假二进制（Windows 用 .bat，其余平台用 shell 脚本）充当 cfst，
// 其退出码为 2，并向 stderr 打印一段带特定标记的文本；随后断言 Run() 返回的错误
// 既包含原始错误包装（speedtest:cfst:wait），也包含该 stderr 标记文本。
func TestCFSTRun_ReturnsStderrOnFailure(t *testing.T) {
	const marker = "cfst-fake-stderr-error-42"
	dir := t.TempDir()

	var binPath string
	if runtime.GOOS == "windows" {
		binPath = filepath.Join(dir, "cfst-fake.bat")
		// @echo off 后向 stderr 打印标记文本，并以退出码 2 结束。
		content := "@echo off\r\necho " + marker + " 1>&2\r\nexit /b 2\r\n"
		require.NoError(t, os.WriteFile(binPath, []byte(content), 0o644))
	} else {
		binPath = filepath.Join(dir, "cfst-fake.sh")
		content := "#!/bin/sh\necho \"" + marker + "\" >&2\nexit 2\n"
		require.NoError(t, os.WriteFile(binPath, []byte(content), 0o755))
	}

	// 直接以未导出字段构造 tester，绕过 NewCFSTTester 对真实 cfst 二进制的探测，
	// 使用一个我们可控的假二进制。
	tester := &CFSTTester{binPath: binPath}
	cfg := &config.CFIPConfig{
		Paths: config.PathConfig{OutputDir: dir},
	}

	_, err := tester.Run(context.Background(), cfg)
	require.Error(t, err, "cfst 以退出码 2 失败时 Run() 应返回错误")
	assert.Contains(t, err.Error(), marker,
		"cfst 真实报错文本（stderr）应回传到错误中")
	assert.Contains(t, err.Error(), "speedtest:cfst:wait",
		"应保留原始错误包装信息")
}
