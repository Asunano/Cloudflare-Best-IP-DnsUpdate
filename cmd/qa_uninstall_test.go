package cmd

import (
	"strings"
	"testing"

	"cfopt/internal/install"
	"cfopt/internal/prompt"
)

// TestUninstall_defaultNoConfirm 空输入（默认 false）应取消卸载，不清理（PRD P0-3 默认不清理防误删）。
func TestUninstall_defaultNoConfirm(t *testing.T) {
	prompt.SetInput(strings.NewReader("\n"))
	defer prompt.SetInput(nil)
	if err := runUninstall(); err != nil {
		t.Fatalf("默认（空）确认应取消卸载，got=%v", err)
	}
}

// TestRemoveDataDir_guard 路径守卫：拒绝危险目录；安全目录可清理且不报错。
func TestRemoveDataDir_guard(t *testing.T) {
	if err := install.RemoveDataDir("/tmp/evil", t.TempDir()); err == nil {
		t.Fatal("应拒绝危险目录 /tmp/evil")
	}
	a := t.TempDir()
	b := t.TempDir()
	if err := install.RemoveDataDir(a, b); err != nil {
		t.Fatalf("安全目录清理不应报错，got=%v", err)
	}
}

// TestUninstall_removerCalledOnConfirm 确认卸载（系统级）后应使用注入的全局命令移除器（验证跨平台移除钩子被调用）。
func TestUninstall_removerCalledOnConfirm(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	origRemover := install.GlobalCommandRemover
	called := false
	install.GlobalCommandRemover = func(dir string, goos string) error { called = true; return nil }
	defer func() { install.GlobalCommandRemover = origRemover }()

	// 系统级模式。
	uninstallSystem = true
	defer func() { uninstallSystem = false }()

	// 确认(y) → 选保留配置(1) → 移除器应被调用。
	prompt.SetInput(strings.NewReader("y\n1\n"))
	defer prompt.SetInput(nil)

	if err := runUninstall(); err != nil {
		t.Fatalf("runUninstall 不应错误: %v", err)
	}
	if !called {
		t.Fatal("确认卸载后应调用全局命令移除器")
	}
}
