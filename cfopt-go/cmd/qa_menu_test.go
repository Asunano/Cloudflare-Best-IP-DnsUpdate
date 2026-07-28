package cmd

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"

	"cfopt/internal/prompt"
)

// TestPrintMenuUsage_listsSixOptions 验证主菜单布局（1 快速部署 / 2 系统健康检测 / 3 查看已配置域名 / 4 同步与调度 / 5 检查更新 / 6 卸载 / 0 退出）。
func TestPrintMenuUsage_listsSixOptions(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	printMenuUsage()
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	for _, want := range []string{
		"快速部署", "系统健康检测", "查看已配置域名", "同步与调度", "检查更新", "卸载", "0) 退出",
	} {
		if !bytes.Contains(out, []byte(want)) {
			t.Fatalf("printMenuUsage 应含菜单项 %q，实际输出:\n%s", want, string(out))
		}
	}
}

// TestRunMenu_interactive_exit 交互模式选 0 应退出并返回 nil（不卡死）。
func TestRunMenu_interactive_exit(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("0\n"))
	defer prompt.SetInput(nil)

	if err := runMenu(); err != nil {
		t.Fatalf("交互 runMenu 选 0 应退出并返回 nil，got=%v", err)
	}
}

// TestRunMenu_interactive_uninstallCancel 选 6（卸载）→ 确认默认 false（n）→ 取消 → 回主菜单 → 选 0 退出。
// 验证菜单路由正确且子流程取消后能回到主循环（不死循环/不卡死）。
func TestRunMenu_interactive_uninstallCancel(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("6\nn\n0\n"))
	defer prompt.SetInput(nil)

	if err := runMenu(); err != nil {
		t.Fatalf("交互 runMenu 卸载取消后应回主菜单并退出，got=%v", err)
	}
}
