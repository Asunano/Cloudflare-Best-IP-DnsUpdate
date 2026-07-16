// Package cmd 实现 cfopt 的 CLI 子命令树（cobra）。
// 所有子命令共享加载配置（config.Load）、初始化日志（common.InitLogger）与进程锁目录。
package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
)

var (
	cfgDir   string // --config-dir，配置文件目录
	logLevel string // --log-level，日志级别
	lockDir  string // --lock-dir，进程锁目录（空则取 global.lock_dir）
)

// rootCmd 根命令。
var rootCmd = &cobra.Command{
	Use:           "cfopt",
	Short:         "cfopt - Cloudflare 优选 IP 与 DNS 同步工具 (Go 重写版)",
	Long:          "cfopt 提供测速、DNS 同步、一键同步、调度 daemon 与配置管理能力。",
	SilenceUsage:  true,
	SilenceErrors: false,
	PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
		common.InitLogger(logLevel)
		return nil
	},
}

// Execute 是 CLI 入口，由 main.go 调用。
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&cfgDir, "config-dir", "conf", "配置文件目录")
	rootCmd.PersistentFlags().StringVar(&logLevel, "log-level", "info", "日志级别: debug|info|warn|error")
	rootCmd.PersistentFlags().StringVar(&lockDir, "lock-dir", "", "进程锁目录（默认取配置 global.lock_dir）")

	rootCmd.AddCommand(
		newSpeedtestCmd(),
		newDNSCommand(),
		newSyncCmd(),
		newScheduleCmd(),
		newConfigCommand(),
		newVersionCmd(),
		newServeCmd(),
	)
}

// loadConfig 加载配置（供需要配置的命令调用），并按需设置进程锁目录。
func loadConfig() (*config.Config, error) {
	cfg, err := config.Load(cfgDir)
	if err != nil {
		return nil, err
	}
	if lockDir == "" && cfg.Global != nil && cfg.Global.LockDir != "" {
		common.SetLockDir(cfg.Global.LockDir)
	}
	return cfg, nil
}

// newHistoryStore 依据全局配置构建历史存储（默认 <data_dir>/history.jsonl）。
func newHistoryStore(cfg *config.Config) (history.HistoryStore, error) {
	dir := "./assets/data"
	if cfg.Global != nil && cfg.Global.DataDir != "" {
		dir = cfg.Global.DataDir
	}
	path := filepath.Join(dir, "history.jsonl")
	return history.NewJSONLStore(path), nil
}
