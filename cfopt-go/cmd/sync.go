package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/sync"
)

// runSyncAll 执行完整同步链路：加载配置 → 构建 Syncer → 获取运行锁 → SyncAll。
func runSyncAll() error {
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
	// F1：测速阶段渲染实时进度条（仅终端可见；nil 表示静默）。
	syncer.SpeedtestProgress = renderSpeedtestProgress
	// T15 单飞运行锁：防止并发 sync 重复测速/写 DNS（非阻塞 fast-fail）。
	rel, lockErr := common.AcquireRunLock(common.RunLockName)
	if lockErr != nil {
		return common.New("cmd:sync:lock", "已有同步进程在运行（cfopt-sync-run）")
	}
	defer func() { _ = rel() }()
	summary, err := syncer.SyncAll(context.Background(), cfg, nil)
	if err != nil {
		return common.Wrap("cmd:sync", err)
	}
	fmt.Printf("sync: 完成 (最优IP=%d updated=%d created=%d deleted=%d)\n",
		summary.BestIPCount, summary.Updated, summary.Created, summary.Deleted)
	printWarnings(summary.Warnings)
	return nil
}

// newSyncCmd 构造 `cfopt sync` 命令：构造 Syncer 跑完整主链路。
func newSyncCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sync",
		Short: "一键：测速 → 提取最优 IP → 同步 CF/DNSPod → 批量更新",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSyncAll()
		},
	}
}

// runSyncSingle 执行单域名同步：按 provider 模块 ID 过滤同步范围。
// modID 为 "cf"（Cloudflare）或 "dnspod"（DNSPod）。
func runSyncSingle(modID, domain string) error {
	fmt.Printf("\n=== 单域名同步: %s (%s) ===\n", domain, modID)

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
	// F1：测速阶段渲染实时进度条。
	syncer.SpeedtestProgress = renderSpeedtestProgress
	// 单飞运行锁：防止并发 sync 重复测速/写 DNS（非阻塞 fast-fail）。
	rel, lockErr := common.AcquireRunLock(common.RunLockName)
	if lockErr != nil {
		return common.New("cmd:sync:lock", "已有同步进程在运行（cfopt-sync-run）")
	}
	defer func() { _ = rel() }()
	summary, err := syncer.SyncAll(context.Background(), cfg, nil, modID)
	if err != nil {
		return common.Wrap("cmd:sync:single", err)
	}
	fmt.Printf("sync: %s 同步完成 (updated=%d created=%d deleted=%d)\n",
		domain, summary.Updated, summary.Created, summary.Deleted)
	printWarnings(summary.Warnings)
	return nil
}
