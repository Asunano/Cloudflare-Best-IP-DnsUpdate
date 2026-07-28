package cmd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"cfopt/internal/install"
)

// presetCFST 在 dir/assets/cfst 预置占位 cfst 二进制，使 ensureCFST 跳过真实网络下载。
func presetCFSTIn(t *testing.T, dir string) {
	t.Helper()
	cfstDir := filepath.Join(dir, "assets", "cfst")
	if err := os.MkdirAll(cfstDir, 0o755); err != nil {
		t.Fatal(err)
	}
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	if err := os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func dirExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// TestRunInstall_idempotent 验证系统级 RunInstall 幂等，且全局命令安装钩子被调用（跨平台分支经注入桩验证）。
func TestRunInstall_idempotent(t *testing.T) {
	orig := install.GlobalCommandInstaller
	called := 0
	install.GlobalCommandInstaller = func(dir, goos string) error { called++; return nil }
	defer func() { install.GlobalCommandInstaller = orig }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "sys")
	cfgDir := filepath.Join(tmp, "conf")
	cfstDir := filepath.Join(dir, "assets", "cfst")
	_ = os.MkdirAll(cfstDir, 0o755)
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	if err := os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}

	opts := install.InstallOptions{Mode: install.ModeSystem, Dir: dir, CfgDir: cfgDir}
	res1, err := install.RunInstall(context.Background(), opts)
	if err != nil || !res1.SelfPlaced || !res1.ConfInit || !res1.GlobalCommandInstalled {
		t.Fatalf("首次 RunInstall 应自安置+生成骨架+全局命令，res=%+v err=%v", res1, err)
	}
	res2, err := install.RunInstall(context.Background(), opts)
	if err != nil || !res2.SelfPlaced || !res2.ConfInit || !res2.GlobalCommandInstalled {
		t.Fatalf("重复 RunInstall 应幂等，res=%v err=%v", res2, err)
	}
	if called != 2 {
		t.Fatalf("全局命令安装器应在两次 RunInstall 各调用一次，called=%d", called)
	}
}

// TestValidateInstallDir_rejectsDangerous 路径守卫：拒绝 /tmp /dev /proc /sys 与 ".."（跨平台归一化后比对）。
func TestValidateInstallDir_rejectsDangerous(t *testing.T) {
	src, _ := os.Executable()
	dangerous := []string{"/tmp/evil", "/dev/null", "/proc/1", "/sys/kernel", "../escape"}
	for _, d := range dangerous {
		if _, err := install.SelfPlace(src, d); err == nil {
			t.Errorf("应拒绝危险安装目录 %q", d)
		}
	}
	// 安全目录应通过守卫（复制失败属其它原因，非守卫拦截）。
	safe := t.TempDir()
	if _, err := install.SelfPlace(src, safe); err != nil {
		t.Logf("安全目录 SelfPlace 返回（可能复制失败，非守卫）: %v", err)
	}
}

// TestHealthPing_noPanic 网络体检仅返回告警，不 panic、不阻塞安装。
func TestHealthPing_noPanic(t *testing.T) {
	_ = install.HealthPing(context.Background())
}

// TestInstall_portable_e2e 端到端冒烟（呼应 Q0）：cfopt install --dir T → 断言 T 内含二进制/conf/cfst
// → cfopt uninstall --dir T --force → 断言 T 被彻底删除、系统零残留。
// cfst 预置到 T/assets/cfst 跳过网络；便携模式不写 PATH（无需 seam 注入即安全）。
func TestInstall_portable_e2e(t *testing.T) {
	// 预置 cfst 到目标目录，避免网络下载。
	tmp := t.TempDir()
	cfstDir := filepath.Join(tmp, "assets", "cfst")
	_ = os.MkdirAll(cfstDir, 0o755)
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	_ = os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755)

	// 安装：便携模式，--dir tmp，--force 跳过确认（非交互环境亦不阻塞）。
	installSystem = false
	installDir = tmp
	installSchedule = false
	installForce = true
	defer func() { installSystem = false; installDir = ""; installSchedule = false; installForce = false }()

	if err := runInstall(); err != nil {
		t.Fatalf("runInstall 失败: %v", err)
	}

	// 断言产物齐全（二进制 / conf / cfst 均在 T 内）。
	bin := filepath.Join(tmp, "cfopt")
	if runtime.GOOS == "windows" {
		bin = filepath.Join(tmp, "cfopt.exe")
	}
	if _, e := os.Stat(bin); e != nil {
		t.Errorf("二进制未落盘 %s: %v", bin, e)
	}
	if _, e := os.Stat(filepath.Join(tmp, "conf", "global.json")); e != nil {
		t.Errorf("conf 未生成: %v", e)
	}
	if _, e := os.Stat(filepath.Join(cfstDir, binName)); e != nil {
		t.Errorf("cfst 未就绪: %v", e)
	}

	// 卸载：便携删目录，--force 跳过确认。
	uninstallSystem = false
	uninstallDir = tmp
	uninstallForce = true
	defer func() { uninstallSystem = false; uninstallDir = ""; uninstallForce = false }()

	if err := runUninstall(); err != nil {
		t.Fatalf("runUninstall 失败: %v", err)
	}
	if _, e := os.Stat(tmp); e == nil {
		t.Errorf("便携卸载后目录应被删除: %s", tmp)
	}
}

// TestRunInstall_portableNoGlobalCommand 便携模式 runInstall 根本不调用全局命令安装器
// （不写 PATH/注册表/LOCALAPPDATA）。注入 spy 断言未被调用（PRD P0-6 / 设计铁律）。
// 仅写临时目录，无系统副作用。
func TestRunInstall_portableNoGlobalCommand(t *testing.T) {
	orig := install.GlobalCommandInstaller
	called := false
	install.GlobalCommandInstaller = func(dir, goos string) error { called = true; return nil }
	defer func() { install.GlobalCommandInstaller = orig }()

	dir := t.TempDir()
	presetCFSTIn(t, dir)

	installSystem = false
	installDir = dir
	installSchedule = false
	installForce = true
	defer func() { installSystem = false; installDir = ""; installSchedule = false; installForce = false }()

	if err := runInstall(); err != nil {
		t.Fatalf("runInstall 失败: %v", err)
	}
	if called {
		t.Error("便携模式 runInstall 不应调用 GlobalCommandInstaller（不写 PATH）")
	}
}

// TestRunInstall_portableScheduleIgnored 便携模式传 --schedule 应被忽略并打印调度提示（Q-C1）。
// 便携仅写临时目录，无系统副作用。
func TestRunInstall_portableScheduleIgnored(t *testing.T) {
	orig := install.GlobalCommandInstaller
	install.GlobalCommandInstaller = func(dir, goos string) error { return nil }
	defer func() { install.GlobalCommandInstaller = orig }()

	dir := t.TempDir()
	presetCFSTIn(t, dir)

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	installSystem = false
	installDir = dir
	installSchedule = true
	installForce = true
	defer func() { installSystem = false; installDir = ""; installSchedule = false; installForce = false }()

	_ = runInstall()
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	s := string(out)
	if !strings.Contains(s, "便携模式已忽略 --schedule") && !strings.Contains(s, "调度为系统级能力") {
		t.Errorf("便携模式传 --schedule 应打印忽略提示，实际:\n%s", s)
	}
}

// TestRunInstall_systemIgnoresDirWithWarning --system 与 --dir 同传时，应以 --system 为准、
// 忽略 --dir 并打印警告（Q-C2）。
// 安全护栏：若系统默认安装目录或 ./conf 已存在（可能是真实安装/既有产物），跳过以免触碰用户数据；
// 否则运行后清理测试写入的 sysDir 与 ./conf（仅当本次新建时才清理）。
func TestRunInstall_systemIgnoresDirWithWarning(t *testing.T) {
	sysDir := defaultInstallDir()
	sysExisted := dirExists(sysDir)
	confExisted := dirExists("conf")

	if sysExisted {
		t.Skipf("系统默认安装目录 %s 已存在，跳过以免触碰真实安装", sysDir)
	}

	orig := install.GlobalCommandInstaller
	install.GlobalCommandInstaller = func(dir, goos string) error { return nil }
	defer func() { install.GlobalCommandInstaller = orig }()

	ro, wo, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	re, we, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = wo, we

	installSystem = true
	ignored := filepath.Join(t.TempDir(), "should-be-ignored")
	installDir = ignored
	installSchedule = false
	installForce = true
	defer func() {
		installSystem = false
		installDir = ""
		installSchedule = false
		installForce = false
	}()

	_ = runInstall()
	_ = wo.Close()
	_ = we.Close()
	os.Stdout, os.Stderr = oldOut, oldErr

	if !sysExisted {
		defer os.RemoveAll(sysDir)
	}
	if !confExisted {
		defer os.RemoveAll("conf")
	}

	out, _ := io.ReadAll(ro)
	errOut, _ := io.ReadAll(re)
	combined := string(out) + string(errOut)
	if !strings.Contains(combined, "忽略") {
		t.Errorf("--system 与 --dir 同传应打印忽略 --dir 的警告，实际:\n%s", combined)
	}
	if strings.Contains(combined, "should-be-ignored") {
		t.Errorf("自安置目录不应包含被忽略的 --dir 路径，实际:\n%s", combined)
	}
	if !strings.Contains(combined, sysDir) {
		t.Errorf("自安置目录应为系统默认目录 %s，实际:\n%s", sysDir, combined)
	}
}
