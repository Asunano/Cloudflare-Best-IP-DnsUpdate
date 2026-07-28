package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
)

// newLogsCmd 构造 `cfopt logs` 命令：查看运行日志或历史记录。
//   - 默认读取 conf/logs/cfopt.log（slog 文本格式），支持 --tail N / --level 过滤；
//   - --history 读取 history.jsonl 历史记录（同样支持 --tail）。
func newLogsCmd() *cobra.Command {
	var (
		tailN    int
		level    string
		histMode bool
	)
	cmd := &cobra.Command{
		Use:   "logs",
		Short: "查看运行日志 / 历史记录",
		Long:  "读取 conf/logs/cfopt.log 运行日志（支持 --tail / --level 过滤）；--history 则读取历史记录 history.jsonl。",
		RunE: func(c *cobra.Command, args []string) error {
			if histMode {
				return runLogsHistory(tailN)
			}
			return runLogsFile(cfgDir, tailN, level)
		},
	}
	cmd.Flags().IntVar(&tailN, "tail", 50, "显示最后 N 行（history 模式同样适用）")
	cmd.Flags().StringVar(&level, "level", "", "按级别过滤: debug|info|warn|error")
	cmd.Flags().BoolVar(&histMode, "history", false, "读取历史记录 history.jsonl 而非运行日志")
	return cmd
}

// runLogsFile 读取并展示运行日志文件，按 tail / level 过滤。
func runLogsFile(cfgDir string, tailN int, level string) error {
	logPath := filepath.Join(cfgDir, "logs", "cfopt.log")
	data, err := os.ReadFile(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("logs: 日志文件不存在: %s（请先运行 cfopt 产生日志）", logPath)
		}
		return common.Wrap("logs:read", err)
	}
	lines := splitLines(string(data))
	lines = tailLines(lines, tailN)
	if level != "" {
		lines = filterByLevel(lines, level)
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	return nil
}

// runLogsHistory 读取并展示历史记录（history.jsonl）。
func runLogsHistory(tailN int) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return err
	}
	recs, err := hist.ReadLatest(tailN)
	if err != nil {
		return common.Wrap("logs:history", err)
	}
	if len(recs) == 0 {
		fmt.Println("（无历史记录）")
		return nil
	}
	for _, e := range recs {
		fmt.Printf("%s  %-16s 成功=%v  %s\n",
			e.Timestamp.Format("2006-01-02 15:04:05"), e.Action, e.Success, e.Detail)
	}
	return nil
}

// splitLines 按行切分，丢弃末尾空行（避免 ReadFile 末尾换行产生空行）。
func splitLines(s string) []string {
	lines := strings.Split(s, "\n")
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// tailLines 取最后 n 行；n<=0 返回全部。
func tailLines(lines []string, n int) []string {
	if n <= 0 || n >= len(lines) {
		return lines
	}
	return lines[len(lines)-n:]
}

// filterByLevel 仅保留级别 <= 阈值的行（rank 越小越严重：ERROR=1 WARN=2 INFO=3 DEBUG=4）。
// 因此 --level error 只看错误，--level info 看 info+warn+error，--level debug 看全部。
// 无 level= 字段的行在过滤模式下被跳过（视为无关噪声）。
func filterByLevel(lines []string, level string) []string {
	thr := levelRank(level)
	if thr == 0 {
		return lines
	}
	var out []string
	for _, l := range lines {
		rank := levelRankInLine(l)
		if rank == 0 {
			continue
		}
		if rank <= thr {
			out = append(out, l)
		}
	}
	return out
}

// levelRank 将级别名映射为数值（DEBUG=4 INFO=3 WARN=2 ERROR=1，未知=0）。
func levelRank(s string) int {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case "DEBUG":
		return 4
	case "INFO":
		return 3
	case "WARN", "WARNING":
		return 2
	case "ERROR":
		return 1
	default:
		return 0
	}
}

// levelRankInLine 从一行 slog 文本中提取 level=XXX 的级别数值。
func levelRankInLine(line string) int {
	idx := strings.Index(line, "level=")
	if idx < 0 {
		return 0
	}
	rest := line[idx+len("level="):]
	if end := strings.IndexAny(rest, " \t"); end >= 0 {
		rest = rest[:end]
	}
	return levelRank(rest)
}
