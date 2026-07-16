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
