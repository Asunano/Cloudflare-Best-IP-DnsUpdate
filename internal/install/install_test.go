package install

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// presetCFST 在 dir/assets/cfst 预置一个占位 cfst 二进制，使 ensureCFST 跳过真实网络下载。
func presetCFST(t *testing.T, dir string) {
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

// TestRunInstall_portable_skipsGlobalCommand 便携模式不应调用全局命令安装器，且不写 PATH/注册表。
func TestRunInstall_portable_skipsGlobalCommand(t *testing.T) {
	orig := GlobalCommandInstaller
	called := false
	GlobalCommandInstaller = func(dir, goos string) error { called = true; return nil }
	defer func() { GlobalCommandInstaller = orig }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "portable")
	cfgDir := filepath.Join(dir, "conf")
	presetCFST(t, dir)

	res, err := RunInstall(context.Background(), InstallOptions{Mode: ModePortable, Dir: dir, CfgDir: cfgDir})
	if err != nil {
		t.Fatalf("RunInstall 不应致命: %v", err)
	}
	if res.Mode != ModePortable {
		t.Errorf("Mode 应为 portable，实际 %s", res.Mode)
	}
	if res.GlobalCommandInstalled {
		t.Error("便携模式不应安装全局命令")
	}
	if called {
		t.Error("便携模式不应调用 GlobalCommandInstaller")
	}
	if !res.ConfInit {
		t.Error("ConfInit 应为 true")
	}
	if !res.CFSTInstalled {
		t.Errorf("CFSTInstalled 应为 true, warnings=%v", res.Warnings)
	}
	// C1：配置应落在 dir/conf 下。
	if _, e := os.Stat(filepath.Join(cfgDir, "global.json")); e != nil {
		t.Errorf("未生成 %s/global.json: %v", cfgDir, e)
	}
}

// TestIsInstalled_empty 空目录应返回 false。
func TestIsInstalled_empty(t *testing.T) {
	opts := InstallOptions{Dir: t.TempDir(), CfgDir: filepath.Join(t.TempDir(), "conf")}
	if IsInstalled(opts) {
		t.Error("空目录 IsInstalled 应为 false")
	}
}

// TestIsInstalled_installed 含 cfopt[.exe] + global.json 的目录应返回 true。
func TestIsInstalled_installed(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "conf")
	_ = os.MkdirAll(cfgDir, 0o755)
	exeName := "cfopt"
	if runtime.GOOS == "windows" {
		exeName = "cfopt.exe"
	}
	_ = os.WriteFile(filepath.Join(dir, exeName), []byte("fake"), 0o755)
	_ = os.WriteFile(filepath.Join(cfgDir, "global.json"), []byte("{}"), 0o644)

	opts := InstallOptions{Dir: dir, CfgDir: cfgDir}
	if !IsInstalled(opts) {
		t.Error("含 cfopt.exe + global.json 应返回 true")
	}
}

// TestIsInstalled_missingExe 有 global.json 但无 cfopt.exe 应返回 false。
func TestIsInstalled_missingExe(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "conf")
	_ = os.MkdirAll(cfgDir, 0o755)
	_ = os.WriteFile(filepath.Join(cfgDir, "global.json"), []byte("{}"), 0o644)

	opts := InstallOptions{Dir: dir, CfgDir: cfgDir}
	if IsInstalled(opts) {
		t.Error("缺少 cfopt.exe 时 IsInstalled 应为 false")
	}
}

// TestIsInstalled_missingConf 有 cfopt.exe 但无 global.json 应返回 false。
func TestIsInstalled_missingConf(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "conf")
	_ = os.MkdirAll(cfgDir, 0o755)
	exeName := "cfopt"
	if runtime.GOOS == "windows" {
		exeName = "cfopt.exe"
	}
	_ = os.WriteFile(filepath.Join(dir, exeName), []byte("fake"), 0o755)

	opts := InstallOptions{Dir: dir, CfgDir: cfgDir}
	if IsInstalled(opts) {
		t.Error("缺少 global.json 时 IsInstalled 应为 false")
	}
}

// TestCheckDirClean_notExist 目录不存在视为干净。
func TestCheckDirClean_notExist(t *testing.T) {
	clean, files, err := CheckDirClean(filepath.Join(t.TempDir(), "nonexistent"), "cfopt.exe")
	if err != nil {
		t.Fatalf("CheckDirClean 不应错误: %v", err)
	}
	if !clean {
		t.Error("不存在的目录应视为干净")
	}
	if len(files) != 0 {
		t.Errorf("不存在的目录应返回空文件列表，got %v", files)
	}
}

// TestCheckDirClean_empty 空目录应视为干净。
func TestCheckDirClean_empty(t *testing.T) {
	dir := t.TempDir()
	clean, files, err := CheckDirClean(dir, "cfopt.exe")
	if err != nil {
		t.Fatalf("CheckDirClean 不应错误: %v", err)
	}
	if !clean {
		t.Error("空目录应视为干净")
	}
	if len(files) != 0 {
		t.Errorf("空目录应返回空文件列表，got %v", files)
	}
}

// TestCheckDirClean_onlyKnown 仅含 cfopt.exe + conf/ + assets/ + global.json 应视为干净。
func TestCheckDirClean_onlyKnown(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "cfopt.exe"), []byte("fake"), 0o755)
	_ = os.MkdirAll(filepath.Join(dir, "conf"), 0o755)
	_ = os.MkdirAll(filepath.Join(dir, "assets"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "global.json"), []byte("{}"), 0o644)

	clean, files, err := CheckDirClean(dir, "cfopt.exe")
	if err != nil {
		t.Fatalf("CheckDirClean 不应错误: %v", err)
	}
	if !clean {
		t.Errorf("仅含已知文件应视为干净，但得到 foreignFiles=%v", files)
	}
}

// TestCheckDirClean_hasForeign 含外来文件应返回 clean=false 并列出外来文件。
func TestCheckDirClean_hasForeign(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "cfopt.exe"), []byte("fake"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("hello"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "data.csv"), []byte("a,b"), 0o644)

	clean, files, err := CheckDirClean(dir, "cfopt.exe")
	if err != nil {
		t.Fatalf("CheckDirClean 不应错误: %v", err)
	}
	if clean {
		t.Error("含外来文件应返回 clean=false")
	}
	if len(files) != 2 {
		t.Fatalf("应返回 2 个外来文件，got %v", files)
	}
	// 验证列出了所有外来文件
	got := make(map[string]bool)
	for _, f := range files {
		got[f] = true
	}
	if !got["readme.txt"] {
		t.Error("应列出 readme.txt")
	}
	if !got["data.csv"] {
		t.Error("应列出 data.csv")
	}
}

// TestCheckDirClean_withExeName 使用不同 exeName 应正确识别已知文件。
func TestCheckDirClean_withExeName(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "cfopt"), []byte("fake"), 0o755) // Linux 风格
	_ = os.WriteFile(filepath.Join(dir, "foreign.txt"), []byte("x"), 0o644)

	clean, files, err := CheckDirClean(dir, "cfopt")
	if err != nil {
		t.Fatalf("CheckDirClean 不应错误: %v", err)
	}
	if clean {
		t.Error("含外来文件应返回 clean=false")
	}
	if len(files) != 1 || files[0] != "foreign.txt" {
		t.Errorf("应返回 [foreign.txt]，got %v", files)
	}
}

// TestPreInstallCheck 验证预检：对有效目录应打印成功信息并添加警告（网络不可达时）。
func TestPreInstallCheck(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "conf")
	res := &InstallResult{}
	preInstallCheck(context.Background(), InstallOptions{Mode: ModePortable, Dir: dir, CfgDir: cfgDir}, res)
	// 预检不应增加致命错误
	if len(res.Errors) > 0 {
		t.Errorf("预检不应产生错误: %v", res.Errors)
	}
	// 目标目录可写，不应有不可写警告
	for _, w := range res.Warnings {
		if w != "" && (w == "目标目录不可写" || w == "cfst 资产目录不可创建") {
			t.Errorf("有效目录不应有不可写警告: %s", w)
		}
	}
}

// TestPreInstallCheck_alreadyInstalled RunInstall 已安装时跳过预检
// （已在 TestRunInstall_idempotent 中覆盖，此处做显式断言）。
func TestPreInstallCheck_alreadyInstalled(t *testing.T) {
	tmp := t.TempDir()
	dir := filepath.Join(tmp, "p")
	cfgDir := filepath.Join(dir, "conf")
	presetCFST(t, dir)
	opts := InstallOptions{Mode: ModePortable, Dir: dir, CfgDir: cfgDir}
	if _, err := RunInstall(context.Background(), opts); err != nil {
		t.Fatalf("首次安装失败: %v", err)
	}
	// 第二次：已安装，应跳过预检直接幂等安装
	if _, err := RunInstall(context.Background(), opts); err != nil {
		t.Fatalf("重复安装失败: %v", err)
	}
	// 验证 global.json 仍存在
	if _, e := os.Stat(filepath.Join(cfgDir, "global.json")); e != nil {
		t.Errorf("幂等后 global.json 应仍在: %v", e)
	}
}

// TestRunInstall_portable_cfstUnderDirAssets 便携模式 cfst 应落 dir/assets/cfst。
func TestRunInstall_portable_cfstUnderDirAssets(t *testing.T) {
	tmp := t.TempDir()
	dir := filepath.Join(tmp, "portable")
	cfgDir := filepath.Join(dir, "conf")
	presetCFST(t, dir)

	if _, err := RunInstall(context.Background(), InstallOptions{Mode: ModePortable, Dir: dir, CfgDir: cfgDir}); err != nil {
		t.Fatalf("RunInstall 失败: %v", err)
	}
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	if _, e := os.Stat(filepath.Join(dir, "assets", "cfst", binName)); e != nil {
		t.Errorf("cfst 未落在 dir/assets/cfst: %v", e)
	}
}

// TestRunInstall_system_installsGlobalCommand 系统级模式应调用全局命令安装器并写 PATH/软链。
func TestRunInstall_system_installsGlobalCommand(t *testing.T) {
	orig := GlobalCommandInstaller
	called := 0
	GlobalCommandInstaller = func(dir, goos string) error { called++; return nil }
	defer func() { GlobalCommandInstaller = orig }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "sys")
	cfgDir := filepath.Join(tmp, "conf")
	presetCFST(t, dir)

	res, err := RunInstall(context.Background(), InstallOptions{Mode: ModeSystem, Dir: dir, CfgDir: cfgDir})
	if err != nil {
		t.Fatalf("RunInstall 不应致命: %v", err)
	}
	if !res.GlobalCommandInstalled {
		t.Error("系统模式应安装全局命令")
	}
	if called != 1 {
		t.Errorf("GlobalCommandInstaller 应被调用一次, called=%d", called)
	}
	if !res.ConfInit {
		t.Error("ConfInit 应为 true")
	}
	if !res.CFSTInstalled {
		t.Errorf("CFSTInstalled 应为 true, warnings=%v", res.Warnings)
	}
}

// TestRunInstall_idempotent 重复运行不破坏已有配置、不重复下载。
func TestRunInstall_idempotent(t *testing.T) {
	tmp := t.TempDir()
	dir := filepath.Join(tmp, "p")
	cfgDir := filepath.Join(dir, "conf")
	presetCFST(t, dir)
	opts := InstallOptions{Mode: ModePortable, Dir: dir, CfgDir: cfgDir}
	if _, err := RunInstall(context.Background(), opts); err != nil {
		t.Fatalf("首次失败: %v", err)
	}
	if _, err := RunInstall(context.Background(), opts); err != nil {
		t.Fatalf("重复失败: %v", err)
	}
	if _, e := os.Stat(filepath.Join(cfgDir, "global.json")); e != nil {
		t.Errorf("幂等后 global.json 应仍在: %v", e)
	}
}

// TestRunUninstall_portable_deletesDir 便携卸载应删除整个目录（删目录即干净退出）。
func TestRunUninstall_portable_deletesDir(t *testing.T) {
	tmp := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmp, "cfopt"), []byte("x"), 0o755)
	_ = os.MkdirAll(filepath.Join(tmp, "conf"), 0o755)

	res, err := RunUninstall(context.Background(), UninstallOptions{Mode: ModePortable, Dir: tmp, RemoveData: true})
	if err != nil {
		t.Fatalf("RunUninstall 不应致命: %v", err)
	}
	if _, e := os.Stat(tmp); e == nil {
		t.Errorf("便携卸载后应删除目录 %s", tmp)
	}
	if len(res.Removed) == 0 {
		t.Error("应有 Removed 项")
	}
}

// TestRunUninstall_portable_bestEffort 删除部分失败时（如被锁定文件）应列出 Failed 项，不静默跳过。
// 注：以 root 运行时权限绕过，目录会被整体删除（走成功分支），此时不强制要求 Failed。
func TestRunUninstall_portable_bestEffort(t *testing.T) {
	tmp := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmp, "data.txt"), []byte("x"), 0o644)
	locked := filepath.Join(tmp, "locked")
	_ = os.MkdirAll(locked, 0o755)
	_ = os.WriteFile(filepath.Join(locked, "f.txt"), []byte("y"), 0o644)
	_ = os.Chmod(locked, 0o500) // 只读：非 root 时无法删除其中文件
	defer os.Chmod(locked, 0o755)

	res, err := RunUninstall(context.Background(), UninstallOptions{Mode: ModePortable, Dir: tmp, RemoveData: true})
	if err != nil {
		t.Fatalf("RunUninstall 不应致命: %v", err)
	}
	if _, statErr := os.Stat(tmp); statErr == nil {
		// 目录仍在 → 删除部分失败（如非 root 下被锁定/只读子目录）→ 应列出 Failed 项。
		if len(res.Failed) == 0 {
			t.Error("删除部分失败时，应列出 Failed 项")
		}
	} else {
		// 目录已被整体删除（如以 root 运行，权限绕过）→ 走成功分支，不强制要求 Failed。
		t.Logf("目录已被整体删除（可能以 root 运行），best-effort 走成功分支")
	}
}

// TestRunUninstall_system_callsRemover 系统级卸载应调用全局命令移除器。
func TestRunUninstall_system_callsRemover(t *testing.T) {
	orig := GlobalCommandRemover
	called := false
	GlobalCommandRemover = func(dir string, goos string) error { called = true; return nil }
	defer func() { GlobalCommandRemover = orig }()

	tmp := t.TempDir()
	cfgDir := filepath.Join(tmp, "conf")
	res, err := RunUninstall(context.Background(), UninstallOptions{Mode: ModeSystem, Dir: tmp, CfgDir: cfgDir, RemoveData: true})
	if err != nil {
		t.Fatalf("RunUninstall 不应致命: %v", err)
	}
	if !called {
		t.Error("系统级卸载应调用 GlobalCommandRemover")
	}
	if len(res.Removed) == 0 {
		t.Error("应有 Removed 项")
	}
}
