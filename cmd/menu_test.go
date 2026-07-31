package cmd

import (
	"bytes"
	"io"
	"os"
	"runtime"
	"testing"
)

func TestRootCmdRegistersNewCommands(t *testing.T) {
	names := map[string]bool{}
	for _, c := range rootCmd.Commands() {
		names[c.Name()] = true
	}
	for _, want := range []string{"install", "quickdeploy", "uninstall", "config", "update", "schedule"} {
		if !names[want] {
			t.Errorf("rootCmd 应注册子命令 %q", want)
		}
	}
	if rootCmd.RunE == nil {
		t.Error("rootCmd.RunE 应挂接 runMenu，否则无参无法进入主菜单")
	}
}

func TestRunMenu_nonInteractive(t *testing.T) {
	// 测试环境 stdout 为管道，IsInteractive()==false → 打印用法即返回 nil，不阻塞。
	if err := runMenu(); err != nil {
		t.Fatalf("非交互 runMenu 应返回 nil，got %v", err)
	}
}

func TestRunScheduleCenter_nonInteractive(t *testing.T) {
	if err := runScheduleCenter(); err != nil {
		t.Fatalf("非交互 runScheduleCenter 应返回 nil，got %v", err)
	}
}

// TestPrintWindowsGuiHint_containsText 验证 GUI 提示文案输出（调用方自行用 runtime.GOOS 门控）。
func TestPrintWindowsGuiHint_containsText(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	printWindowsGuiHint()
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	if !bytes.Contains(out, []byte("GUI")) {
		t.Fatalf("printWindowsGuiHint 应含 GUI 提示，实际:\n%s", string(out))
	}
}

// TestRunMenu_windowsHintNotOnNonWindows 非 Windows 下主菜单不应打印 GUI 提示（避免噪音）。
func TestRunMenu_windowsHintNotOnNonWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("仅在非 Windows 验证不打印提示")
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	_ = runMenu() // 非交互，打印用法
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	if bytes.Contains(out, []byte("GUI 版本")) {
		t.Fatalf("非 Windows 主菜单不应打印 GUI 提示，实际:\n%s", string(out))
	}
}
