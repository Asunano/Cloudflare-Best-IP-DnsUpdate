// Package main 是 cfopt Go 重写版的 CLI 入口。
// 所有业务逻辑在 internal/ 与 cmd/ 中，main 仅负责拉起 cobra 命令树。
package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"

	"cfopt/cmd"
	"cfopt/internal/prompt"
	"golang.org/x/term"
)

func main() {
	// Windows 双击/控制台场景：stdin 为字符设备时强制进入交互模式，
	// 因为 prompt.IsInteractive() 默认检查 os.Stdout，Win10+ 双击时 stdout 可能是管道，
	// 导致菜单进入非交互分支（仅打印用法即退出）。
	if runtime.GOOS == "windows" {
		// 用 term.IsTerminal 检测 Windows 控制台（比 os.Stdin.Stat() ModeCharDevice 更可靠，
		// 因为 term.IsTerminal 使用 Windows Console API GetConsoleMode，双击场景下更稳定）。
		if term.IsTerminal(int(os.Stdin.Fd())) {
			// stdin 是控制台（非管道/重定向），说明用户通过双击或 cmd.exe 直接运行。
			// 覆盖 interactiveFunc 为恒 true，使菜单始终进入交互循环。
			prompt.SetInteractiveFunc(func() bool { return true })
		}
	}

	cmd.Execute()

	// Windows 交互模式下，退出前等待用户按回车，防止控制台窗口闪退。
	// 条件：Windows + stdin 是控制台 + IsInteractive() 为 true。
	if runtime.GOOS == "windows" && term.IsTerminal(int(os.Stdin.Fd())) && prompt.IsInteractive() {
		fmt.Print("\n按 Enter 键退出...")
		_, _ = bufio.NewReader(os.Stdin).ReadBytes('\n')
	}
}
