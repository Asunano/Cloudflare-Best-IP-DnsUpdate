package cmd

import (
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/scheduler"
)

// scheduleOnce 标记 --once（单次运行，供 cron 唤醒）。
var scheduleOnce bool

// newScheduleCmd 构造 `cfopt schedule` 命令（含 install/uninstall/start/stop/run 子命令）。
// 无子命令时等同于 `run`（常驻或 --once 单次）。
func newScheduleCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "schedule",
		Short: "启动调度器 / 常驻 daemon（带看门狗超时保护）",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSchedule("run")
		},
	}
	cmd.PersistentFlags().BoolVar(&scheduleOnce, "once", false, "单次运行后退出（供 cron 直接唤醒二进制）")
	cmd.AddCommand(
		&cobra.Command{Use: "install", Short: "注册系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("install") }},
		&cobra.Command{Use: "uninstall", Short: "注销系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("uninstall") }},
		&cobra.Command{Use: "start", Short: "启动系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("start") }},
		&cobra.Command{Use: "stop", Short: "停止系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("stop") }},
		&cobra.Command{Use: "run", Short: "前台运行（常驻或 --once 单次）", RunE: func(c *cobra.Command, a []string) error { return runSchedule("run") }},
	)
	return cmd
}

// runSchedule 构建 Scheduler/Daemon 并执行服务动作。
func runSchedule(action string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return err
	}
	sched, err := scheduler.NewScheduler(cfg, hist)
	if err != nil {
		return common.Wrap("cmd:schedule:build", err)
	}
	daemon := scheduler.NewDaemon(sched, cfg, parseInterval(cfg), scheduleOnce)
	return daemon.RunService(action)
}

// parseInterval 解析调度间隔（global.schedule.interval，Go duration 字符串），默认 6h。
func parseInterval(cfg *config.Config) time.Duration {
	if cfg.Global != nil && cfg.Global.Schedule.Interval != "" {
		if d, err := time.ParseDuration(cfg.Global.Schedule.Interval); err == nil {
			return d
		}
	}
	return 6 * time.Hour
}
