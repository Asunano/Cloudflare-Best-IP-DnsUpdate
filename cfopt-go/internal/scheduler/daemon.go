package scheduler

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kardianos/service"

	"cfopt/internal/common"
	"cfopt/internal/config"
)

// Daemon 常驻轻量 daemon，基于 kardianos/service 注册为跨平台系统服务
// （Windows Service / systemd / launchd），并支持 --once 单次运行（供外部 cron 直接唤醒二进制）。
//
// 依赖 github.com/kardianos/service：跨平台系统服务注册（Windows Service / systemd / launchd），
// 无需平台特化代码即可 install/uninstall/start/stop，并处理信号优雅退出。
type Daemon struct {
	scheduler *Scheduler
	cfg       *config.Config
	interval  time.Duration
	once      bool

	cancel context.CancelFunc
}

// NewDaemon 构造 Daemon。interval<=0 时默认 6h。
func NewDaemon(sched *Scheduler, cfg *config.Config, interval time.Duration, once bool) *Daemon {
	if interval <= 0 {
		interval = 6 * time.Hour
	}
	return &Daemon{scheduler: sched, cfg: cfg, interval: interval, once: once}
}

// Start 由 service 框架调用：启动后台循环（非阻塞），立即返回。
func (d *Daemon) Start(s service.Service) error {
	ctx, cancel := context.WithCancel(context.Background())
	d.cancel = cancel
	go d.runLoop(ctx)
	return nil
}

// Stop 由 service 框架调用：取消循环。
func (d *Daemon) Stop(s service.Service) error {
	if d.cancel != nil {
		d.cancel()
	}
	return nil
}

// runLoop 主循环：--once 时单次执行后退出；否则每 interval 执行一次直到 ctx 取消。
func (d *Daemon) runLoop(ctx context.Context) {
	if d.once {
		if err := d.scheduler.RunOnce(ctx, d.cfg); err != nil {
			common.Error("daemon: 单次运行失败", "err", err.Error())
		}
		return
	}
	ticker := time.NewTicker(d.interval)
	defer ticker.Stop()
	if err := d.scheduler.RunOnce(ctx, d.cfg); err != nil {
		common.Error("daemon: 调度执行失败", "err", err.Error())
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := d.scheduler.RunOnce(ctx, d.cfg); err != nil {
				common.Error("daemon: 调度执行失败", "err", err.Error())
			}
		}
	}
}

// serviceConfig 构造 kardianos/service 配置。
func serviceConfig() *service.Config {
	return &service.Config{
		Name:        "cfopt",
		DisplayName: "cfopt Go 调度服务",
		Description: "Cloudflare 优选 IP 与 DNS 同步常驻服务",
	}
}

// RunService 根据 action 执行服务控制：install / uninstall / start / stop / run。
//   - install/uninstall/start/stop：调用系统服务管理器。
//   - run：若 --once 则前台单次执行后退出（供 cron 唤醒）；否则以服务方式常驻（kardianos 负责信号处理优雅退出）。
func (d *Daemon) RunService(action string) error {
	svc, err := service.New(d, serviceConfig())
	if err != nil {
		return common.Wrap("daemon:new", err)
	}
	switch action {
	case "install":
		return common.Wrap("daemon:install", svc.Install())
	case "uninstall":
		return common.Wrap("daemon:uninstall", svc.Uninstall())
	case "start":
		return common.Wrap("daemon:start", svc.Start())
	case "stop":
		return common.Wrap("daemon:stop", svc.Stop())
	case "run":
		if d.once {
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return d.scheduler.RunOnce(ctx, d.cfg)
		}
		return common.Wrap("daemon:run", svc.Run())
	default:
		return common.New("daemon", "未知服务动作: "+action)
	}
}

// Status 返回系统服务运行状态：running / stopped / unknown。
// 复用包内 serviceConfig() 构造 kardianos 配置并查询状态。
func (d *Daemon) Status() (string, error) {
	svc, err := service.New(d, serviceConfig())
	if err != nil {
		return "unknown", common.Wrap("daemon:status:new", err)
	}
	st, err := svc.Status()
	if err != nil {
		return "unknown", common.Wrap("daemon:status", err)
	}
	switch st {
	case service.StatusRunning:
		return "running", nil
	case service.StatusStopped:
		return "stopped", nil
	default:
		return "unknown", nil
	}
}
