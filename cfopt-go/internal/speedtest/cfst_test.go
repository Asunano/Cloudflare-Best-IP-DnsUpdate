package speedtest

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

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

// TestResolveCFSTBinary_Order 验证四级探测顺序：CFSTPath > CFST.Binary > cfst/cfst.exe > assets/cfst/cfst[.exe]。
func TestResolveCFSTBinary_Order(t *testing.T) {
	dir := t.TempDir()

	// 第4级：assets/cfst/cfst[.exe]（与 cfst fetch 安装名一致），directory=dir。
	lvl4 := filepath.Join(dir, "cfst")
	if runtime.GOOS == "windows" {
		lvl4 += ".exe"
	}
	require.NoError(t, os.WriteFile(lvl4, []byte("bin"), 0o755))

	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Directory: dir}}
	assert.Equal(t, lvl4, resolveCFSTBinary(cfg), "无其他配置时应落到第4级探测（assets/cfst/cfst[.exe]）")

	// 第2级：CFST.Binary 优先于第4级。
	bin2 := filepath.Join(dir, "mycfst.bin")
	require.NoError(t, os.WriteFile(bin2, []byte("bin"), 0o755))
	cfg.CFST.Binary = bin2
	assert.Equal(t, bin2, resolveCFSTBinary(cfg), "CFST.Binary 应优先于第4级")

	// 第1级：CFSTPath 最高优先。
	p1 := filepath.Join(dir, "explicit.bin")
	require.NoError(t, os.WriteFile(p1, []byte("bin"), 0o755))
	cfg.CFSTPath = p1
	assert.Equal(t, p1, resolveCFSTBinary(cfg), "CFSTPath 应最高优先")
}

// TestResolveCFSTBinary_Level3Local 验证第3级：无 CFSTPath/Binary、且第4级不存在时，命中工作目录 cfst/cfst.exe。
func TestResolveCFSTBinary_Level3Local(t *testing.T) {
	dir := t.TempDir()
	// 切到临时目录作为 cwd（隔离，避免污染源码树），结束后恢复。
	old, err := os.Getwd()
	require.NoError(t, err)
	require.NoError(t, os.Chdir(dir))
	defer func() { _ = os.Chdir(old) }()

	base := "cfst"
	if runtime.GOOS == "windows" {
		base = "cfst.exe"
	}
	require.NoError(t, os.WriteFile(filepath.Join(dir, base), []byte("bin"), 0o755))

	// 空配置（directory 默认 assets/cfst，此处不存在第4级）。
	cfg := &config.CFIPConfig{}
	assert.Equal(t, base, resolveCFSTBinary(cfg), "应命中工作目录 cfst/cfst.exe（第3级）")
}

// TestNewCFSTTester_MissingFriendlyError 验证 cfst 缺失时返回含 `cfopt cfst fetch` 与发布页的友好错误。
func TestNewCFSTTester_MissingFriendlyError(t *testing.T) {
	dir := t.TempDir()
	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Directory: dir}} // 第4级文件不存在
	_, err := NewCFSTTester(cfg)
	require.Error(t, err, "cfst 不存在应返回错误")
	assert.Contains(t, err.Error(), "cfopt cfst fetch", "错误应提示 cfopt cfst fetch")
	assert.Contains(t, err.Error(), "github.com/XIU2/CloudflareSpeedTest/releases", "错误应给出官方发布页")
}

// TestCFSTBuildCmd_FlagMapping 验证 P1-6 全部 flag 映射正确，且下限保护生效：
//   - Threads→-n、PingTimes→-t、DownloadCount→-dn、DownloadTime→-dt
//   - Port→-tp、URL→-url、Colo→-httping -cfcolo
//   - LatencyMax→-tl、PacketLossMax→-tlr、SpeedMin→-sl、ShowCount→-p
//   - AllIP→-allip、DisableDownload→-dd
func TestCFSTBuildCmd_FlagMapping(t *testing.T) {
	tester := &CFSTTester{binPath: "dummy"}
	cfg := &config.CFIPConfig{
		CFST: config.CFSTConfig{
			Threads:        16,
			PingTimes:      4,
			DownloadCount:  10,
			DownloadTime:   12,
			Port:           443,
			URL:            "https://example.com/test.dat",
			Colo:           "HKG",
			LatencyMax:     200,
			PacketLossMax:  1.5,
			SpeedMin:       5.5,
			ShowCount:      20,
			AllIP:          true,
			DisableDownload: true,
		},
	}

	args := tester.buildCmd(cfg, "out.csv")

	// 基础输出与参数位置校验。
	assert.Contains(t, args, "-o")
	assert.Equal(t, "out.csv", args[indexOf(args, "-o")+1])

	// 逐字段映射校验。
	checks := []struct {
		flag  string
		value string
	}{
		{"-n", "16"},
		{"-t", "4"},
		{"-dn", "10"},
		{"-dt", "12"},
		{"-tp", "443"},
		{"-url", "https://example.com/test.dat"},
		{"-tl", "200"},
		{"-tlr", "1.5"},
		{"-sl", "5.5"},
		{"-p", "20"},
	}
	for _, c := range checks {
		idx := indexOf(args, c.flag)
		require.NotEqual(t, -1, idx, "flag %s 应出现在参数中", c.flag)
		require.Less(t, idx+1, len(args), "flag %s 后应紧跟参数值", c.flag)
		assert.Equal(t, c.value, args[idx+1], "flag %s 参数值错误", c.flag)
	}
	// 地区码需通过 -httping -cfcolo 表达。
	assert.Contains(t, args, "-httping")
	assert.Contains(t, args, "-cfcolo")
	assert.Equal(t, "HKG", args[indexOf(args, "-cfcolo")+1])
	// 开关类 flag。
	assert.Contains(t, args, "-allip")
	assert.Contains(t, args, "-dd")
	// 旧的错误 flag 不应出现。
	assert.NotContains(t, args, "-cf", "v2.3.5 不存在 -cf flag")
}

// TestCFSTBuildCmd_LowerBoundGuards 验证 Threads/PingTimes 为 0 时不拼装对应 flag（下限保护）。
func TestCFSTBuildCmd_LowerBoundGuards(t *testing.T) {
	tester := &CFSTTester{binPath: "dummy"}
	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Threads: 0, PingTimes: 0}}
	args := tester.buildCmd(cfg, "out.csv")
	assert.NotContains(t, args, "-n", "Threads=0 不应拼装 -n")
	assert.NotContains(t, args, "-t", "PingTimes=0 不应拼装 -t")
}

// TestCFSTBuildCmd_DefaultTimeout 验证默认超时常量存在且为 300s。
func TestCFSTBuildCmd_DefaultTimeout(t *testing.T) {
	assert.Equal(t, 300*time.Second, DefaultSpeedtestTimeout)
}

// TestNewCFSTTester_NilCfg 验证 cfg=nil 时立即返回错误，不 panic。
func TestNewCFSTTester_NilCfg(t *testing.T) {
	_, err := NewCFSTTester(nil)
	require.Error(t, err, "cfg=nil 应返回错误")
	assert.Contains(t, err.Error(), "配置为空", "应提示配置为空")
}

// TestNewCFSTTester_FindsAtAssetsCwd 验证多路径轮询命中 CWD/assets/cfst/cfst[.exe]。
func TestNewCFSTTester_FindsAtAssetsCwd(t *testing.T) {
	dir := t.TempDir()
	old, err := os.Getwd()
	require.NoError(t, err)
	require.NoError(t, os.Chdir(dir))
	defer func() { _ = os.Chdir(old) }()

	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	assetsDir := filepath.Join(dir, "assets", "cfst")
	require.NoError(t, os.MkdirAll(assetsDir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(assetsDir, binName), []byte("bin"), 0o755))

	// CFST.Directory 指向一个不存在的路径，使 resolveCFSTBinary 返回空目录下的路径 → 不命中
	// 但 CWD/assets/cfst/cfst[.exe] 是最后一个候选，应命中。
	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Directory: filepath.Join(dir, "nonexistent")}}
	tester, err := NewCFSTTester(cfg)
	require.NoError(t, err, "CWD/assets/cfst 下有 cfst 时应成功")
	require.NotNil(t, tester, "返回的 tester 不应为 nil")
	// NewCFSTTester 使用 filepath.Join(".", "assets", "cfst", binName) 作为最后候选，
	// 得到的是相对路径 assets/cfst/cfst[.exe]（与 CWD 相关）。
	expectedRel := filepath.Join("assets", "cfst", binName)
	assert.Equal(t, expectedRel, tester.binPath, "应命中 ./assets/cfst 路径")
}

// TestNewCFSTTester_AllPathsEmpty 验证 candidates 中的空串被跳过，不 panic。
func TestNewCFSTTester_AllPathsEmpty(t *testing.T) {
	// 构造一个空的 cfg，但确保 resolveCFSTBinary 返回空串（模拟极端情况）
	// 注意：resolveCFSTBinary 在正常情况下不会返回空串（第4级默认返回 assets/cfst/cfst[.exe]），
	// 此处测试 NewCFSTTester 内部的空串守卫逻辑。
	dir := t.TempDir()
	cfg := &config.CFIPConfig{CFST: config.CFSTConfig{Directory: filepath.Join(dir, "void")}}
	_, err := NewCFSTTester(cfg)
	require.Error(t, err, "全部路径不存在时应返回错误")
	assert.Contains(t, err.Error(), "cfopt cfst fetch")
}
