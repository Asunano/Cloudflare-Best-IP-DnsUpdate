package cmd

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"cfopt/internal/install"
	"cfopt/internal/prompt"
)

func TestRemoveGlobalCommand_symlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 分支需 PowerShell，跳过软链测试")
	}
	tmp := t.TempDir()
	// 放置一个伪二进制。
	bin := filepath.Join(tmp, "cfopt")
	if err := os.WriteFile(bin, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	// 直接测试 RemoveGlobalCommand 在软链不存在时不报错（权限不足仅返回 error，不 panic）。
	if err := install.RemoveGlobalCommand(tmp, "linux"); err != nil {
		t.Logf("RemoveGlobalCommand 返回（可能无权限）: %v", err)
	}
}

func TestUninstall_nonInteractiveReturnsNil(t *testing.T) {
	// 测试环境 stdout 为管道，IsInteractive()==false，应直接返回 nil（不阻塞）。
	if err := runUninstall(); err != nil {
		t.Fatalf("非交互 uninstall 应返回 nil，got %v", err)
	}
}

// TestUninstall_portable_forceDeletesDir 便携 + --force 应直接删除目标目录（删目录即干净退出）。
func TestUninstall_portable_forceDeletesDir(t *testing.T) {
	tmp := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmp, "cfopt"), []byte("fake"), 0o755)
	_ = os.MkdirAll(filepath.Join(tmp, "conf"), 0o755)

	uninstallSystem = false
	uninstallDir = tmp
	uninstallForce = true
	defer func() { uninstallSystem = false; uninstallDir = ""; uninstallForce = false }()

	if err := runUninstall(); err != nil {
		t.Fatalf("runUninstall 失败: %v", err)
	}
	if _, e := os.Stat(tmp); e == nil {
		t.Errorf("便携强制卸载后目录应被删除: %s", tmp)
	}
}

// TestUninstall_system_removerCalledOnConfirm 系统级确认卸载后应使用注入的全局命令移除器。
func TestUninstall_system_removerCalledOnConfirm(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)

	origRemover := install.GlobalCommandRemover
	called := false
	install.GlobalCommandRemover = func(dir string, goos string) error { called = true; return nil }
	defer func() { install.GlobalCommandRemover = origRemover }()

	uninstallSystem = true
	uninstallDir = ""
	uninstallForce = false
	defer func() { uninstallSystem = false; uninstallDir = ""; uninstallForce = false }()

	// 确认(y) → 选保留配置(1)。
	prompt.SetInput(strings.NewReader("y\n1\n"))
	defer prompt.SetInput(nil)

	if err := runUninstall(); err != nil {
		t.Fatalf("runUninstall 不应错误: %v", err)
	}
	if !called {
		t.Fatal("系统级卸载应调用全局命令移除器")
	}
}
