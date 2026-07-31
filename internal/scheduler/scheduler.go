package scheduler

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/sync"
)

// networkProbeURLs 网络前置探测目标（任一可达即视为网络正常）。
// 选取实际会被调用的上游端点，避免无谓外联。
var networkProbeURLs = []string{
	"https://api.cloudflare.com/client/v4",
	"https://dnspod.tencentcloudapi.com",
}

// networkProbeTimeout 单次探测超时。
const networkProbeTimeout = 5 * time.Second

// RunOnce 执行一次完整调度（测速 + 同步），受看门狗超时保护。
func (s *Scheduler) RunOnce(ctx context.Context, cfg *config.Config) error {
	// T15 单飞运行锁：防止并发调度重复跑主链路。
	// 锁冲突时记录警告并跳过本次调度（而非返回错误），避免面板 crontab ��� exit 1 反复重试。
	rel, lockErr := common.AcquireRunLock(common.RunLockName)
	if lockErr != nil {
		common.Warn("scheduler: 跳过本次调度 — 已有同步进程在运行（cfopt-sync-run）")
		return nil
	}
	defer func() { _ = rel() }()

	// T18 网络前置探测：网络不可达时跳过本次调度，避免无效 API 调用与超时浪费。
	if err := networkPrecheck(ctx); err != nil {
		common.Warn("scheduler: 网络前置探测失败，跳过本次调度", "err", err.Error())
		return common.Wrap("scheduler:precheck", err)
	}

	timeout := s.computeTimeout(cfg)
	wd := NewWatchdog(timeout)
	common.Info("scheduler: 开始调度", "timeout", timeout.String())
	return wd.Guard(ctx, func(ctx context.Context) error {
		_, err := s.syncer.SyncAll(ctx, cfg, nil)
		return err
	})
}

// networkPrecheck 探测网络连通性：对 networkProbeURLs 逐个做 HEAD 请求，
// 任一成功即返回 nil；全部失败（或 ctx 取消）返回错误。
func networkPrecheck(ctx context.Context) error {
	client := &http.Client{Timeout: networkProbeTimeout}
	probeCtx, cancel := context.WithTimeout(ctx, networkProbeTimeout*2)
	defer cancel()
	var lastErr error
	for _, u := range networkProbeURLs {
		req, err := http.NewRequestWithContext(probeCtx, http.MethodHead, u, nil)
		if err != nil {
			lastErr = err
			continue
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		_ = resp.Body.Close()
		// 任何 2xx/3xx/4xx 均视为网络可达（4xx 来自服务器响应，说明链路通）。
		if resp.StatusCode < 500 {
			return nil
		}
		lastErr = fmt.Errorf("probe %s 返回 %d", u, resp.StatusCode)
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("所有探测目标均不可达")
	}
	return lastErr
}

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

// runTimeoutPerJob 单次串行 cfst 测速（HTTPing, -n 50）的保守耗时估算。
// 用户实测约 5.5min；考虑地区/网络波动与「全零速度重测」重跑一次（最坏约 11min），
// 取 15min 留足余量，确保正常多线路同步（数倍于此）不被误杀。
const runTimeoutPerJob = 15 * time.Minute

// runTimeoutBuffer 测速之外的固定开销（模块同步 HTTP 调用、IP 提取、历史写入等）。
const runTimeoutBuffer = 2 * time.Minute

// runTimeoutFloor / runTimeoutCeil 看门狗超时的上下限保护，避免极端配置下超时过短或过长。
const (
	runTimeoutFloor = 10 * time.Minute
	runTimeoutCeil  = 3 * time.Hour
)

// computeTimeout 估算单次调度（测速+同步）的看门狗超时：
//  1. 若 Global.Schedule.WatchdogTimeout 配置合法且 >0，直接采用（用户精确控制，优先级最高）。
//  2. 否则按串行 cfst 测速任务数估算：任务数 × 单次耗时 + 缓冲（含上下限保护）。
//
// 旧公式（基础 120s + IP数×60/线程数，下限 600s）错误地按"线程数"并行估算，
// 而 SyncAll 的域名级与逐线路测速均为串行执行，多线路域名会结构性超时（见 Task#12）。
func (s *Scheduler) computeTimeout(cfg *config.Config) time.Duration {
	if cfg != nil && cfg.Global != nil {
		if d, err := time.ParseDuration(cfg.Global.Schedule.WatchdogTimeout); err == nil && d > 0 {
			return d
		}
	}
	jobs := 1
	if s.syncer != nil {
		jobs = s.syncer.SpeedtestJobCount(cfg)
	}
	estimated := runTimeoutBuffer + time.Duration(jobs)*runTimeoutPerJob
	if estimated < runTimeoutFloor {
		estimated = runTimeoutFloor
	}
	if estimated > runTimeoutCeil {
		estimated = runTimeoutCeil
	}
	return estimated
}
