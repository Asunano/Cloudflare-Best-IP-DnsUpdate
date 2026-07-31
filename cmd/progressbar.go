package cmd

import (
	"fmt"
	"os"
)

// progressBarWidth 进度条字符宽度。
const progressBarWidth = 30

// renderSpeedtestProgress 测速进度回调：仅首条和最后一条时输出简短状态文字，不渲染进度条。
func renderSpeedtestProgress(stage string, cur, total int) {
	// 首条：通知用户测速已启动（仅在终端非日志流时打印，但此处统一用 fmt.Fprintln 保证不混入日志）。
	// 最后一条：通知用户测速完成。
	if cur == 1 && total > 0 {
		fmt.Fprintln(os.Stderr, "⏳ 测速中...（约 3-5 分钟）")
	}
	if cur >= total && total > 0 {
		fmt.Fprintln(os.Stderr, "✓ 测速完成")
	}
}

// printWarnings 把非阻断告警打印到 stderr（与进度条/日志同流，终端可见）。
func printWarnings(warns []string) {
	for _, w := range warns {
		fmt.Fprintln(os.Stderr, w)
	}
}

func printErrors(errs []string) {
	for _, e := range errs {
		fmt.Fprintln(os.Stderr, "错误: "+e)
	}
}
