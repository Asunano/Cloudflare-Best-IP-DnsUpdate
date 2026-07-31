package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/history"
	"cfopt/internal/speedtest"
	"cfopt/internal/sync"
)

// newSpeedtestCmd 构造 `cfopt speedtest` 命令：单次测速并生成 .iplist。
func newSpeedtestCmd() *cobra.Command {
	var output string
	cmd := &cobra.Command{
		Use:   "speedtest",
		Short: "单次测速，生成 .iplist / .csv",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			tester, err := speedtest.NewCFSTTester()
			if err != nil {
				return common.Wrap("cmd:speedtest:tester", err)
			}
			ctx := context.Background()
			start := time.Now()
			results, runErr := tester.Run(ctx, "./assets/data/cf-ip", renderSpeedtestProgress)
			elapsed := time.Since(start)

			// P1-5：无论成功失败，均写入 speedtest 历史。
			if hist, herr := newHistoryStore(cfg); herr == nil && hist != nil {
				detail := fmt.Sprintf("count=%d duration=%s", len(results), elapsed.Round(time.Millisecond))
				_ = hist.Append(history.HistoryEntry{Action: "speedtest", Detail: detail, Success: runErr == nil})
			}

			if runErr != nil {
				return common.Wrap("cmd:speedtest:run", runErr)
			}
			common.Info("speedtest: 完成", "count", len(results))

			fmt.Printf("测速结果（共 %d 条）：\n", len(results))
			for i, r := range results {
				fmt.Printf("  %d. %s 延迟=%.2fms 速度=%.2fMB/s 地区=%s\n", i+1, r.IP, r.Latency, r.Speed, r.Colo)
			}

			recs := tester.ToIPList(results)
			// 按 take_ip_num 截断（默认 5）。
			take := 5
			if take > 0 && len(recs) > take {
				recs = recs[:take]
			}
			if output == "" {
				output = "./assets/data/cf-ip/best_ips.iplist"
			}
			if err := sync.WriteIPList(recs, output); err != nil {
				return common.Wrap("cmd:speedtest:write", err)
			}
			fmt.Printf("已生成 IP 列表: %s\n", output)
			return nil
		},
	}
	cmd.Flags().StringVar(&output, "output", "", "生成的 .iplist 输出路径（默认 <output_dir>/best_ips.iplist）")
	return cmd
}
