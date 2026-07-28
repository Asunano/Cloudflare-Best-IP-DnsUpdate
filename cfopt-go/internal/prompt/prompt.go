// Package prompt 提供轻量级终端问答/菜单原语，仅依赖 Go 标准库 + 官方扩展 golang.org/x/term
// （仅用于 AskSecret 静默输入，非 TUI 框架）。所有函数可单元测试：输入来自可注入的 input
// （默认 os.Stdin），测试可通过 SetInput 注入 strings.Reader。
//
// 设计原则：
//   - 不依赖任何第三方 TUI / CLI 交互库（bubbletea 等一律不用）。
//   - 非交互终端（stdout 非字符设备）下，MenuLoop 返回 ErrNotInteractive，由上层打印用法，不阻塞。
//   - AskSecret 在 TTY 下用 term.ReadPassword 不回显；非 TTY 退化为普通读（CI/测试友好）。
package prompt

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"golang.org/x/term"
)

// ErrNotInteractive 非交互终端错误（MenuLoop 在非 TTY 时返回）。
var ErrNotInteractive = errors.New("prompt: not interactive")

// input 可注入的输入源，默认 os.Stdin；测试用 SetInput 覆盖。
var input io.Reader = os.Stdin

// bin 围绕 input 的单例缓冲读取器（避免每次 readLine 重建 bufio 导致 read-ahead 吞掉后续输入）。
var bin *bufio.Reader

// SetInput 注入输入源（供单元测试）。传 nil 恢复默认 os.Stdin。
func SetInput(r io.Reader) {
	if r == nil {
		input = os.Stdin
	} else {
		input = r
	}
	bin = nil // 切换输入源时重建缓冲读取器
}

// reader 返回（惰性创建）单例缓冲读取器。
func reader() *bufio.Reader {
	if bin == nil {
		bin = bufio.NewReader(input)
	}
	return bin
}

// readLine 从 input 读取一行并去除末尾换行符。
func readLine() (string, error) {
	line, err := reader().ReadString('\n')
	return trimNewline(line), err
}

// trimNewline 去除字符串末尾的 \n / \r。
func trimNewline(s string) string {
	s = strings.TrimSuffix(s, "\n")
	s = strings.TrimSuffix(s, "\r")
	return s
}

// interactiveFunc 决定是否为交互终端；默认实现检查 os.Stdout 字符设备，测试可覆盖。
var interactiveFunc = func() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

// SetInteractiveFunc 覆盖交互终端判定（供单元测试）。传 nil 恢复默认实现。
func SetInteractiveFunc(f func() bool) {
	if f == nil {
		interactiveFunc = func() bool {
			fi, err := os.Stdout.Stat()
			if err != nil {
				return false
			}
			return (fi.Mode() & os.ModeCharDevice) != 0
		}
		return
	}
	interactiveFunc = f
}

// IsInteractive 标准输出是否为字符设备（TTY）。
// 复用 cmd/config.go 既有 isInteractive 逻辑：检测 os.Stdout 的 ModeCharDevice 位。
func IsInteractive() bool {
	return interactiveFunc()
}

// Ask 单行输入，回车取默认 def。非交互终端同样读取（通常来自管道），空行返回默认。
func Ask(prompt, def string) string {
	fmt.Printf("%s [%s]: ", prompt, def)
	line, _ := readLine()
	if strings.TrimSpace(line) == "" {
		return def
	}
	return strings.TrimSpace(line)
}

// AskSecret 静默输入（不回显），返回明文。
// TTY 下使用 golang.org/x/term.ReadPassword；若不可用（非 TTY / 出错）退化为普通读并注释原因。
func AskSecret(prompt string) (string, error) {
	fmt.Print(prompt + ": ")
	if IsInteractive() {
		if fd := int(os.Stdin.Fd()); term.IsTerminal(fd) {
			// 静默密码输入（不回显）。
			b, err := term.ReadPassword(fd)
			fmt.Println()
			if err == nil {
				return string(b), nil
			}
			// 读取失败（极端情况）退化为明文读。
			fmt.Fprintln(os.Stderr, "提示: 无法切换到静默输入，已退化为明文读取（不推荐）。")
		}
	}
	line, err := readLine()
	fmt.Println()
	return line, err
}

// Confirm y/N 确认，def 为默认（回车采用）。接受 y/yes/1/true 为 true；n/no/0/false 为 false。
func Confirm(prompt string, def bool) bool {
	suffix := "y/N"
	if def {
		suffix = "Y/n"
	}
	fmt.Printf("%s [%s]: ", prompt, suffix)
	line, _ := readLine()
	line = strings.ToLower(strings.TrimSpace(line))
	if line == "" {
		return def
	}
	switch line {
	case "y", "yes", "1", "true", "是":
		return true
	case "n", "no", "0", "false", "否":
		return false
	default:
		return def
	}
}

// AskChoice 编号选择；items 为空返回错误。toLabel 决定展示文案。选择后返回对应项。
func AskChoice[T any](prompt string, items []T, toLabel func(T) string) (T, error) {
	var zero T
	if len(items) == 0 {
		return zero, fmt.Errorf("prompt: 空选项列表")
	}
	fmt.Println(prompt)
	for i, it := range items {
		fmt.Printf("  %d) %s\n", i+1, toLabel(it))
	}
	for {
		fmt.Printf("请选择 [1-%d，0 取消]: ", len(items))
		line, _ := readLine()
		n, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil {
			fmt.Printf("无效输入，请输入 1-%d 之间的数字。\n", len(items))
			continue
		}
		if n == 0 {
			return zero, fmt.Errorf("prompt: 用户取消选择")
		}
		if n < 1 || n > len(items) {
			fmt.Printf("无效输入，请输入 1-%d 之间的数字。\n", len(items))
			continue
		}
		return items[n-1], nil
	}
}

// MenuItem 菜单项：Label 显示文案，Run 选中后执行。
type MenuItem struct {
	Label string
	Run   func() error
}

// MenuLoop 打印数字菜单并循环；选 0 退出（返回 nil）；非交互返回 ErrNotInteractive。
// 单项执行出错仅打印提示并继续循环，不中断菜单。
func MenuLoop(title string, items []MenuItem) error {
	if !IsInteractive() {
		printMenu(title, items)
		fmt.Println("当前为非交互终端（管道/重定向），请直接使用具体子命令，例如：")
		for i, it := range items {
			fmt.Printf("  # %d) %s\n", i+1, it.Label)
		}
		return ErrNotInteractive
	}
	for {
		printMenu(title, items)
		fmt.Printf("请输入序号 [0-%d]: ", len(items))
		line, _ := readLine()
		n, err := strconv.Atoi(strings.TrimSpace(line))
		if err != nil || n < 0 || n > len(items) {
			fmt.Println("无效输入，请重试。")
			continue
		}
		if n == 0 {
			return nil
		}
		if err := items[n-1].Run(); err != nil {
			fmt.Printf("执行出错: %v\n", err)
		}
	}
}

// printMenu 打印标题与所有菜单项（1-based 编号）。
func printMenu(title string, items []MenuItem) {
	fmt.Println()
	fmt.Println(title)
	for i, it := range items {
		fmt.Printf("  %d) %s\n", i+1, it.Label)
	}
	fmt.Println("  0) 退出")
}
