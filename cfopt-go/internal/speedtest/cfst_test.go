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

	// 预置 outputDir/ip.txt，使 resolveIPFile 命中本地缓存分支而短路，
	// 不再回退到真实访问 cloudflare.com 拉取 IP 段。
	// 本测试只验证 Run 对 cfst 失败 stderr 的回传行为，与 IP 文件来源无关；
	// 预置后即便在无外网 CI 下也不会因 30s 超时/网络错误而变慢或 flaky。
	require.NoError(t, os.WriteFile(filepath.Join(dir, "ip.txt"), []byte("203.0.113.0/24\n"), 0o644))

	_, err := tester.Run(context.Background(), cfg)
	require.Error(t, err, "cfst 以退出码 2 失败时 Run() 应返回错误")
	assert.Contains(t, err.Error(), marker,
		"cfst 真实报错文本（stderr）应回传到错误中")
	assert.Contains(t, err.Error(), "speedtest:cfst:wait",
		"应保留原始错误包装信息")
}

// TestCFSTBuildCmd_ColoFlag 验证 buildCmd 在配置了地区码（colo）时，
// 使用 cfst v2.3.5 合法的 flag：-httping -cfcolo <colo>，而不再使用错误的 -cf。
//
// 背景：cfopt-go 依赖外部 sidecar cfst（CloudflareSpeedTest）做测速，
// v2.3.5 没有 -cf 这个 flag（会报 "flag provided but not defined: -cf"），
// 正确的地区过滤 flag 是 -cfcolo，且它仅在 HTTPing 模式下生效，因此需一并开启 -httping。
func TestCFSTBuildCmd_ColoFlag(t *testing.T) {
	// buildCmd 是包私有方法，同包内可直接调用；binPath 不参与参数拼装，填占位即可。
	tester := &CFSTTester{binPath: "dummy"}
	cfg := &config.CFIPConfig{
		CFST: config.CFSTConfig{
			Colo:    "HKG,NRT",
			Threads: 0, // 不影响本次断言，但保持默认不触发其它分支
		},
	}

	args := tester.buildCmd(cfg, "out.csv")

	// 1) 不应再出现错误的 -cf flag。
	assert.NotContains(t, args, "-cf", "cfst v2.3.5 不存在 -cf flag，不应被拼入")

	// 2) 应包含 -httping 与 -cfcolo。
	assert.Contains(t, args, "-httping", "colo 配置下应开启 HTTPing 模式")
	assert.Contains(t, args, "-cfcolo", "colo 配置下应使用 -cfcolo 地区过滤 flag")

	// 3) -cfcolo 之后必须紧邻地区码 "HKG,NRT"。
	idx := indexOf(args, "-cfcolo")
	require.NotEqual(t, -1, idx, "-cfcolo 应存在于 args 中")
	require.Less(t, idx+1, len(args), "-cfcolo 后应紧跟地区码参数")
	assert.Equal(t, "HKG,NRT", args[idx+1],
		"-cfcolo 之后应紧邻配置的地区码 HKG,NRT")

	// 4) -httping 应在 -cfcolo 之前（顺序：先开 HTTPing 模式，再给地区过滤）。
	httpingIdx := indexOf(args, "-httping")
	require.NotEqual(t, -1, httpingIdx, "-httping 应存在于 args 中")
	assert.Less(t, httpingIdx, idx, "-httping 应出现在 -cfcolo 之前")
}

// indexOf 返回 target 在切片中首次出现的下标，未找到返回 -1。
func indexOf(slice []string, target string) int {
	for i, v := range slice {
		if v == target {
			return i
		}
	}
	return -1
}
