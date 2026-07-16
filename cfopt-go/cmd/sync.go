package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/sync"
)

// newSyncCmd 构造 `cfopt sync` 命令：构造 Syncer 跑完整主链路。
func newSyncCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sync",
		Short: "一键：测速 → 提取最优 IP → 同步 CF/DNSPod → 批量更新",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			hist, err := newHistoryStore(cfg)
			if err != nil {
				return err
			}
			syncer, err := sync.BuildSyncerFromConfig(cfg, hist)
			if err != nil {
				return common.Wrap("cmd:sync:build", err)
			}
			if _, err := syncer.SyncAll(context.Background(), cfg); err != nil {
				return common.Wrap("cmd:sync", err)
			}
			fmt.Println("sync: 完成")
			return nil
		},
	}
}
