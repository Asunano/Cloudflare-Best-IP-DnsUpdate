// Package scheduler 负责任务调度与常驻 daemon（基于 kardianos/service），
// 提供看门狗超时保护（context + goroutine）。
package scheduler

import (
	"context"
	"fmt"
	"time"
)

// Watchdog 超时看门狗：用 context.WithTimeout + goroutine 实现超时杀（超时返回明确错误）。
// 对应原 run.sh 的 start_watchdog / setsid + pkill。
type Watchdog struct {
	timeout time.Duration
}

// NewWatchdog 构造 Watchdog；timeout<=0 时默认 30 分钟。
func NewWatchdog(timeout time.Duration) *Watchdog {
	if timeout <= 0 {
		timeout = 30 * time.Minute
	}
	return &Watchdog{timeout: timeout}
}

// Guard 在超时约束下执行 fn。fn 必须接收并使用传入的 ctx（派生自父 ctx + 超时），
// 本工程链路（exec.CommandContext / http ctx）均透传该 ctx，故超时后上下文取消可真正驱动
// 子进程/请求退出（避免 cfst 等成为孤儿进程继续占用带宽）。超时返回明确错误。
func (w *Watchdog) Guard(ctx context.Context, fn func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, w.timeout)
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- fn(ctx) }()

	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return fmt.Errorf("watchdog: 任务超时 %s: %w", w.timeout, ctx.Err())
	}
}
