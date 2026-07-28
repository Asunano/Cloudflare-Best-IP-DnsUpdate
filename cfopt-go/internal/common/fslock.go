package common

import (
	"os"
	"path/filepath"
	"sync"
	"time"
)

// ReleaseFunc 释放锁的函数类型。
type ReleaseFunc func() error

var (
	lockDirMu sync.RWMutex
	lockDir   = "locks" // 锁文件根目录，可由 SetLockDir 覆盖
)

// SetLockDir 设置进程锁根目录（绝对或相对），应在 Acquire 前调用。
func SetLockDir(dir string) {
	lockDirMu.Lock()
	defer lockDirMu.Unlock()
	if dir != "" {
		lockDir = dir
	}
}

// LockDir 返回当前锁根目录。
func LockDir() string {
	lockDirMu.RLock()
	defer lockDirMu.RUnlock()
	return lockDir
}

// staleThreshold 残留锁判定阈值（与原 Bash 一致：30 分钟）。
const staleThreshold = 30 * time.Minute

// Acquire 获取名为 name 的进程锁，返回释放函数 ReleaseFunc。
//
// 实现采用 os.Mkdir 原子目录锁（无 CGO，跨平台 Windows/macOS/Linux 均可运行），
// 对应原 Bash 的 `flock -n`（非阻塞）语义：锁已被持有时立即返回错误，而非阻塞等待。
// 因此它是“单实例/单次运行”的跨进程守护锁，适用于调度器/守护进程防止重复启动。
//
// 注意：本锁仅保证跨进程互斥，不保证同一进程内的多个 goroutine 串行化。
// 若某包（如 history）需要对并发调用做串行化保护，应在包内使用 sync.Mutex
// （可叠加本锁做跨进程安全），而非依赖 Acquire 阻塞。
//
// 若发现超过 staleThreshold 的残留锁，则先清除以避免上次异常退出导致的死锁。
func Acquire(name string) (ReleaseFunc, error) {
	lockDirMu.RLock()
	base := lockDir
	lockDirMu.RUnlock()

	if err := os.MkdirAll(base, 0o700); err != nil {
		return nil, Wrap("fslock:mkdir", err)
	}
	dir := filepath.Join(base, name+".lock")

	// 清理残留锁：目录存在且超过阈值则删除
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		if time.Since(fi.ModTime()) > staleThreshold {
			_ = os.RemoveAll(dir)
		}
	}

	if err := os.Mkdir(dir, 0o700); err != nil {
		return nil, Wrap("fslock:acquire", err)
	}

	release := func() error {
		if err := os.RemoveAll(dir); err != nil {
			return Wrap("fslock:release", err)
		}
		return nil
	}
	return release, nil
}

// RunLockName 单飞运行锁名。cfopt sync 与 schedule run --once 共用此锁，
// 确保同一时刻全局仅一个同步主链路在跑（避免重复测速/重复写 DNS）。
// 锁路径为 global.lock_dir/cfopt-sync-run.lock。
const RunLockName = "cfopt-sync-run"

// AcquireRunLock 获取单飞运行锁（基于现有 os.Mkdir 原子目录锁 + 30min 残留清理），
// 非阻塞 fast-fail：锁已被占用立即返回 error（不阻塞等待）。返回的 ReleaseFunc 删除锁目录。
//
// 该锁仅保证「跨进程单次运行」互斥；同一进程内的多个 goroutine 应通过其它手段串行化。
func AcquireRunLock(name string) (ReleaseFunc, error) {
	return Acquire(name)
}
