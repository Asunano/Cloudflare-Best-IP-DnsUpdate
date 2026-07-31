package prompt

import (
	"strings"
	"testing"
)

// withInput 注入输入源并在测试后恢复默认。
func withInput(t *testing.T, s string) {
	t.Helper()
	SetInput(strings.NewReader(s))
	t.Cleanup(func() { SetInput(nil) })
}

func TestAsk_usesDefaultOnEmpty(t *testing.T) {
	withInput(t, "\n")
	got := Ask("名字", "默认名")
	if got != "默认名" {
		t.Fatalf("Ask 空输入应取默认，got=%q", got)
	}
}

func TestAsk_returnsTyped(t *testing.T) {
	withInput(t, "hello\n")
	got := Ask("名字", "默认名")
	if got != "hello" {
		t.Fatalf("Ask 应返回输入值，got=%q", got)
	}
}

func TestAskSecret_fallbackReadsLine(t *testing.T) {
	// 测试环境非 TTY，AskSecret 退化为明文读。
	withInput(t, "secret-token\n")
	got, err := AskSecret("Token")
	if err != nil {
		t.Fatalf("AskSecret 不应返回错误: %v", err)
	}
	if got != "secret-token" {
		t.Fatalf("AskSecret 应返回输入明文，got=%q", got)
	}
}

func TestConfirm_defaultAndYes(t *testing.T) {
	withInput(t, "\n")
	if !Confirm("确认?", true) {
		t.Fatal("Confirm 空输入应取默认 true")
	}
	withInput(t, "n\n")
	if Confirm("确认?", true) {
		t.Fatal("Confirm 输入 n 应返回 false")
	}
	withInput(t, "y\n")
	if !Confirm("确认?", false) {
		t.Fatal("Confirm 输入 y 应返回 true")
	}
}

func TestAskChoice_selectsItem(t *testing.T) {
	items := []string{"apple", "banana", "cherry"}
	withInput(t, "2\n")
	got, err := AskChoice("选水果", items, func(s string) string { return s })
	if err != nil {
		t.Fatalf("AskChoice 不应错误: %v", err)
	}
	if got != "banana" {
		t.Fatalf("AskChoice 应返回第 2 项，got=%q", got)
	}
}

func TestAskChoice_invalidThenValid(t *testing.T) {
	items := []string{"a", "b"}
	withInput(t, "9\n0\n2\n")
	_, err := AskChoice("选", items, func(s string) string { return s })
	// 9 非法、0 取消应返回错误；这里用循环直到有效，但我们传入 9/0 会先触发取消。
	if err == nil {
		t.Fatal("AskChoice 输入 0 应返回取消错误")
	}
}

func TestAskChoice_emptyItems(t *testing.T) {
	_, err := AskChoice("选", []string{}, func(s string) string { return s })
	if err == nil {
		t.Fatal("AskChoice 空列表应返回错误")
	}
}

func TestMenuLoop_nonInteractiveReturnsErr(t *testing.T) {
	// 测试环境下 stdout 为管道，IsInteractive()==false。
	err := MenuLoop("测试菜单", []MenuItem{
		{Label: "选项A", Run: func() error { return nil }},
	})
	if err != ErrNotInteractive {
		t.Fatalf("非交互 MenuLoop 应返回 ErrNotInteractive，got=%v", err)
	}
}

func TestIsInteractive_type(t *testing.T) {
	// 仅确认函数可调用且不 panic。
	_ = IsInteractive()
}
