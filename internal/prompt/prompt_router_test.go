package prompt

import (
	"testing"
)

// TestMenuLoop_interactive_selectAndExit 验证交互模式下选中项被执行、选 0 退出且不卡死。
func TestMenuLoop_interactive_selectAndExit(t *testing.T) {
	orig := interactiveFunc
	interactiveFunc = func() bool { return true }
	defer func() { interactiveFunc = orig }()

	var ran int
	withInput(t, "1\n0\n")
	if err := MenuLoop("主菜单", []MenuItem{
		{Label: "选项A", Run: func() error { ran++; return nil }},
	}); err != nil {
		t.Fatalf("交互 MenuLoop 选 0 应退出并返回 nil，got=%v", err)
	}
	if ran != 1 {
		t.Fatalf("选 1 应执行对应项恰好一次，ran=%d", ran)
	}
}

// TestMenuLoop_interactive_invalidRetryThenExit 验证非法输入提示重输、选 0 退出，不 panic/不无限循环。
func TestMenuLoop_interactive_invalidRetryThenExit(t *testing.T) {
	orig := interactiveFunc
	interactiveFunc = func() bool { return true }
	defer func() { interactiveFunc = orig }()

	withInput(t, "9\n0\n")
	if err := MenuLoop("主菜单", []MenuItem{
		{Label: "选项A", Run: func() error { return nil }},
	}); err != nil {
		t.Fatalf("交互 MenuLoop 应返回 nil，got=%v", err)
	}
}

// TestConfirm_defaultFalse 验证空输入取默认 false（PRD P0-5 默认不清理）。
func TestConfirm_defaultFalse(t *testing.T) {
	withInput(t, "\n")
	if Confirm("确认?", false) {
		t.Fatal("Confirm 空输入 + 默认 false 应返回 false")
	}
}

// TestAskChoice_zeroCancels 验证输入 0 返回取消错误（不静默吞掉）。
func TestAskChoice_zeroCancels(t *testing.T) {
	items := []string{"a", "b"}
	withInput(t, "0\n")
	if _, err := AskChoice("选", items, func(s string) string { return s }); err == nil {
		t.Fatal("AskChoice 输入 0 应返回取消错误")
	}
}
