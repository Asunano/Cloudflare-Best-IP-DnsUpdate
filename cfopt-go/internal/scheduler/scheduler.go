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
	// T15 单飞运行锁：防止并发调度重复跑主链路（非阻塞 fast-fail）。
	rel, lockErr := common.AcquireRunLock(common.RunLockName)
	if lockErr != nil {
		return common.New("scheduler:runlock", "已有调度/同步进程在运行（cfopt-sync-run）")
	}
	defer func() { _ = rel() }()

	// T18 网络前置探测：网络不可达时跳过本次调度，避免无效 API 调用与超时浪费。
	if err := networkPrecheck(ctx); err != nil {
		common.Warn("scheduler: 网络前置探测失败，跳过本次调度", "err", err.Error())
		return common.Wrap("scheduler:precheck", err)
	}

	timeout := s.CalcTimeout(s.ipCount(cfg), s.threads(cfg))
	wd := NewWatchdog(timeout)
	common.Info("scheduler: 开始调度", "timeout", timeout.String())
	return wd.Guard(ctx, func() error {
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
