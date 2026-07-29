package cmd

import (
	"fmt"
	"os"
	"strings"
)

// progressBarWidth 进度条字符宽度。
const progressBarWidth = 30

// renderSpeedtestProgress 把测速进度渲染为单行实时进度条（\r 覆盖，结尾换行）。
// 设计为 speedtest.ProgressFunc：stage 当前恒为 "speedtest"，cur/total 为 cfst "X / Y"。
func renderSpeedtestProgress(stage string, cur, total int) {
	pct := 0
	filled := 0
	if total > 0 {
		pct = cur * 100 / total
		filled = cur * progressBarWidth / total
	}
	if filled > progressBarWidth {
		filled = progressBarWidth
	}
	bar := strings.Repeat("=", filled) + strings.Repeat(" ", progressBarWidth-filled)
	// 用 \r 覆盖同一行；最后一条（cur>=total）补换行，避免后续输出顶到进度行上。
	if cur >= total && total > 0 {
		fmt.Fprintf(os.Stderr, "\r  [%s] %3d%% (%d/%d)\n", bar, pct, cur, total)
	} else {
		fmt.Fprintf(os.Stderr, "\r  [%s] %3d%% (%d/%d)", bar, pct, cur, total)
	}
}

// printWarnings 把非阻断告警打印到 stderr（与进度条/日志同流，终端可见）。
func printWarnings(warns []string) {
	for _, w := range warns {
		fmt.Fprintln(os.Stderr, w)
	}
}
