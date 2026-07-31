package install

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// exeNameFor 返回当前平台的可执行文件名。
func exeNameFor() string {
	if runtime.GOOS == "windows" {
		return "cfopt.exe"
	}
	return "cfopt"
}

// forceConfDirBlocked 把 CfgDir 设为一个「父级是文件」的路径，使 ProvisionConf 的
// MkdirAll 必然失败（not a directory），从而触发安装致命错误用于验证回滚。
func forceConfDirBlocked(t *testing.T, dir string) string {
	t.Helper()
	blocker := filepath.Join(dir, "blocker-file") // 普通文件
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(blocker, "conf") // blocker-file/conf → MkdirAll 报错
}

// TestRunInstall_rollbackOnFatal 系统模式安装中遇到致命错误（conf 骨架失败）应回滚
// 已写入项（自安置二进制 + 全局命令），并置 RolledBack=true。
func TestRunInstall_rollbackOnFatal(t *testing.T) {
	origInstaller := GlobalCommandInstaller
	origRemover := GlobalCommandRemover
	var removerCalled bool
	var installerCalled bool
	GlobalCommandInstaller = func(dir, goos string) error { installerCalled = true; return nil }
	GlobalCommandRemover = func(dir string, goos string) error { removerCalled = true; return nil }
	defer func() {
		GlobalCommandInstaller = origInstaller
		GlobalCommandRemover = origRemover
	}()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "sys")
	presetCFST(t, dir) // 跳过真实 cfst 下载，避免网络依赖
	cfgDir := forceConfDirBlocked(t, dir)

	res, err := RunInstall(context.Background(), InstallOptions{Mode: ModeSystem, Dir: dir, CfgDir: cfgDir})
	if err != nil {
		t.Fatalf("RunInstall 不应返回致命 err: %v", err)
	}
	if len(res.Errors) == 0 {
		t.Fatal("预期 conf 骨架失败产生致命错误，但未发生")
	}
	if !res.RolledBack {
		t.Error("出现致命错误应回滚并置 RolledBack=true")
	}
	if !installerCalled {
		t.Error("系统模式应调用 GlobalCommandInstaller")
	}
	if !removerCalled {
		t.Error("回滚应调用 GlobalCommandRemover 撤销全局命令")
	}
	// 自安置的二进制应在回滚中被删除。
	dst := filepath.Join(dir, exeNameFor())
	if _, e := os.Stat(dst); e == nil {
		t.Errorf("回滚后自安置二进制应被删除: %s", dst)
	}
}

// TestRunInstall_rollbackKeepsPreExistingBinary 回滚不应删除用户原有的二进制：
// 若目标二进制在自安置前已存在，则不登记回滚，避免误删用户文件。
func TestRunInstall_rollbackKeepsPreExistingBinary(t *testing.T) {
	origInstaller := GlobalCommandInstaller
	GlobalCommandInstaller = func(dir, goos string) error { return nil }
	defer func() { GlobalCommandInstaller = origInstaller }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "sys")
	presetCFST(t, dir)
	cfgDir := forceConfDirBlocked(t, dir)

	// 预置一个与目标同名的二进制（内容任意），模拟「已存在」。
	dst := filepath.Join(dir, exeNameFor())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, []byte("preexisting"), 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := RunInstall(context.Background(), InstallOptions{Mode: ModeSystem, Dir: dir, CfgDir: cfgDir})
	if err != nil {
		t.Fatalf("RunInstall 不应返回致命 err: %v", err)
	}
	if !res.RolledBack {
		t.Error("应触发回滚")
	}
	if _, e := os.Stat(dst); e != nil {
		t.Errorf("回滚不应删除用户原有二进制: %s (%v)", dst, e)
	}
}

// TestRunInstall_noRollbackOnSuccess 成功安装不应回滚，二进制应保留，RolledBack=false。
func TestRunInstall_noRollbackOnSuccess(t *testing.T) {
	origInstaller := GlobalCommandInstaller
	GlobalCommandInstaller = func(dir, goos string) error { return nil }
	defer func() { GlobalCommandInstaller = origInstaller }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "sys")
	cfgDir := filepath.Join(dir, "conf")
	presetCFST(t, dir)

	res, err := RunInstall(context.Background(), InstallOptions{Mode: ModeSystem, Dir: dir, CfgDir: cfgDir})
	if err != nil {
		t.Fatalf("RunInstall 失败: %v", err)
	}
	if res.RolledBack {
		t.Error("成功安装不应回滚")
	}
	if len(res.Errors) != 0 {
		t.Errorf("成功安装不应有致命错误: %v", res.Errors)
	}
	dst := filepath.Join(dir, exeNameFor())
	if _, e := os.Stat(dst); e != nil {
		t.Errorf("成功安装后二进制应保留: %s (%v)", dst, e)
	}
}
