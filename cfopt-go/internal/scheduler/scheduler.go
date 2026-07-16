package scheduler

import (
	"context"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/sync"
)

// Scheduler 调度编排：以看门狗超时保护执行 RunOnce（两阶段：阶段一测速、阶段二同步）。
// 阶段一与阶段二在 Syncer.SyncAll 内部串联完成（先 tester.Run 测速，再提取最优 IP 并同步）。
type Scheduler struct {
	syncer *sync.Syncer
}

// NewScheduler 从配置构造 Scheduler（内部构建 Syncer，并接入历史存储）。
func NewScheduler(cfg *config.Config, hist history.HistoryStore) (*Scheduler, error) {
	syncer, err := sync.BuildSyncerFromConfig(cfg, hist)
	if err != nil {
		return nil, common.Wrap("scheduler:build", err)
	}
	return &Scheduler{syncer: syncer}, nil
}

// RunOnce 执行一次完整调度（测速 + 同步），受看门狗超时保护。
func (s *Scheduler) RunOnce(ctx context.Context, cfg *config.Config) error {
	timeout := s.CalcTimeout(s.ipCount(cfg), s.threads(cfg))
	wd := NewWatchdog(timeout)
	common.Info("scheduler: 开始调度", "timeout", timeout.String())
	return wd.Guard(ctx, func() error {
		_, err := s.syncer.SyncAll(ctx, cfg)
		return err
	})
}

// CalcTimeout 按 IP 数量与线程数动态计算超时（300s–3600s）。
// 公式（对应原 run.sh calculate_timeout）：基础 60s + (IP数量*3 / 线程数)，下限 300s，上限 3600s。
func (s *Scheduler) CalcTimeout(ipCount, threads int) time.Duration {
	if threads < 1 {
		threads = 1
	}
	if ipCount < 1 {
		ipCount = 20
	}
	calculated := 60 + (ipCount*3)/threads
	if calculated < 300 {
		calculated = 300
	}
	if calculated > 3600 {
		calculated = 3600
	}
	return time.Duration(calculated) * time.Second
}

func (s *Scheduler) ipCount(cfg *config.Config) int {
	if cfg.CFIP == nil {
		return 20
	}
	if cfg.CFIP.SpeedTest.TakeIPNum > 0 {
		return cfg.CFIP.SpeedTest.TakeIPNum
	}
	if cfg.CFIP.CFST.ShowCount > 0 {
		return cfg.CFIP.CFST.ShowCount
	}
	return 20
}

func (s *Scheduler) threads(cfg *config.Config) int {
	if cfg.CFIP == nil || cfg.CFIP.CFST.Threads <= 0 {
		return 200
	}
	return cfg.CFIP.CFST.Threads
}
