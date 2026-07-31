package scheduler

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestWatchdog_PassesDerivedCtx 锁死 Task#10 修复：
// Guard 必须把派生的（带超时的）ctx 传入 fn，而非父 ctx。
// 旧实现 fn func() error 完全收不到超时 ctx，导致 cfst 在超时后成为孤儿进程。
func TestWatchdog_PassesDerivedCtx(t *testing.T) {
	wd := NewWatchdog(50 * time.Millisecond)
	// fn 通过带缓冲通道回报「是否观察到派生 ctx 取消」，避免 Guard 先返回超时、
	// fn 尚未观察到取消造成的竞态。
	fnObservedCancel := make(chan bool, 1)
	err := wd.Guard(context.Background(), func(ctx context.Context) error {
		select {
		case <-ctx.Done():
			fnObservedCancel <- true
			return ctx.Err()
		case <-time.After(2 * time.Second):
			fnObservedCancel <- false
			return nil // 若没收到取消，说明 ctx 断链（旧 bug）
		}
	})
	require.Error(t, err)

	// 等待 fn 实际观察取消（Guard 可能因超时先返回，但 fn 必然随后观察到派生 ctx 取消）。
	select {
	case got := <-fnObservedCancel:
		assert.True(t, got, "fn 必须收到派生的超时 ctx 取消信号")
	case <-time.After(3 * time.Second):
		t.Fatal("fn 未返回，可能死锁")
	}
	assert.ErrorIs(t, err, context.DeadlineExceeded)
}

// TestWatchdog_FnReturnPropagated 正常完成：fn 的返回值应被原样透传。
func TestWatchdog_FnReturnPropagated(t *testing.T) {
	wd := NewWatchdog(time.Minute)
	want := assert.AnError
	got := wd.Guard(context.Background(), func(context.Context) error {
		return want
	})
	assert.Equal(t, want, got)
}
