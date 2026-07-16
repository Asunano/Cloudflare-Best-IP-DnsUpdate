package cmd

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
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
			if cfg.CFIP == nil {
				return common.New("cmd:speedtest", "缺少 cf-ip 配置")
			}
			tester, err := speedtest.NewCFSTTester(cfg.CFIP)
			if err != nil {
				return common.Wrap("cmd:speedtest:tester", err)
			}
			ctx := context.Background()
			results, err := tester.Run(ctx, cfg.CFIP)
			if err != nil {
				return common.Wrap("cmd:speedtest:run", err)
			}
			common.Info("speedtest: 完成", "count", len(results))

			fmt.Printf("测速结果（共 %d 条）：\n", len(results))
			for i, r := range results {
				fmt.Printf("  %d. %s 延迟=%.2fms 速度=%.2fMB/s 地区=%s\n", i+1, r.IP, r.Latency, r.Speed, r.Colo)
			}

			recs := tester.ToIPList(results)
			if output == "" {
				output = filepath.Join(cfg.CFIP.Paths.OutputDir, "best_ips.iplist")
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
