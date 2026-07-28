package common

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// setupLockDir 为每个测试准备独立的临时锁根目录，避免污染包级全局 lockDir / 工作目录。
func setupLockDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	SetLockDir(dir)
	return dir
}

func lockPath(dir, name string) string {
	return filepath.Join(dir, name+".lock")
}

// TestAcquire_ReturnsReleaseFunc 验证 Acquire 返回非 nil 的 ReleaseFunc，且锁目录被创建。
func TestAcquire_ReturnsReleaseFunc(t *testing.T) {
	dir := setupLockDir(t)

	rel, err := Acquire("unittest-a")
	require.NoError(t, err)
	require.NotNil(t, rel)

	// 锁目录应已存在。
	_, statErr := os.Stat(lockPath(dir, "unittest-a"))
	assert.NoError(t, statErr, "持锁期间锁目录应存在")

	// 释放后目录应被清除。
	require.NoError(t, rel())
	_, statErr = os.Stat(lockPath(dir, "unittest-a"))
	assert.True(t, os.IsNotExist(statErr), "release 后锁目录应被清除")
}

// TestAcquire_DoubleAcquireErrors 验证已持锁时再次 Acquire 必须报错（而非脏成功）。
// 这是 fslock 的核心不变量：同一把锁不能被并发/重入成功获取。
func TestAcquire_DoubleAcquireErrors(t *testing.T) {
	setupLockDir(t)

	rel1, err := Acquire("unittest-b")
	require.NoError(t, err)
	require.NotNil(t, rel1)

	// 第二次获取同一把锁：os.Mkdir 对已存在目录返回 EEXIST -> 应返回 error。
	_, err2 := Acquire("unittest-b")
	require.Error(t, err2, "已持锁时再次 Acquire 必须报错，绝不能脏成功")
	assert.Contains(t, err2.Error(), "fslock")

	require.NoError(t, rel1())
}

// TestAcquire_ReacquireAfterRelease 验证释放后可再次成功获取。
func TestAcquire_ReacquireAfterRelease(t *testing.T) {
	dir := setupLockDir(t)

	rel, err := Acquire("unittest-c")
	require.NoError(t, err)
	require.NoError(t, rel())

	// 释放后再次获取应成功。
	rel2, err := Acquire("unittest-c")
	require.NoError(t, err, "释放后应能再次获取同一把锁")
	require.NoError(t, rel2())
	_, statErr := os.Stat(lockPath(dir, "unittest-c"))
	assert.True(t, os.IsNotExist(statErr))
}

// TestAcquire_IndependentLocks 验证不同名称的锁互不干扰。
func TestAcquire_IndependentLocks(t *testing.T) {
	setupLockDir(t)

	relA, err := Acquire("lock-x")
	require.NoError(t, err)
	relB, err := Acquire("lock-y")
	require.NoError(t, err, "不同名称的锁应可同时持有")

	require.NoError(t, relA())
	require.NoError(t, relB())
}

// TestAcquireRunLock_SingleFlight 验证单飞运行锁的 fast-fail 语义：
// 一次只允许一个持有者，释放后他人方可获取（用于 sync / schedule 防并发重复运行）。
func TestAcquireRunLock_SingleFlight(t *testing.T) {
	dir := setupLockDir(t)

	rel, err := AcquireRunLock(RunLockName)
	require.NoError(t, err, "首次获取运行锁应成功")
	require.NotNil(t, rel)

	// 锁已持有：并发获取必须立即失败（不阻塞）。
	done := make(chan error, 1)
	go func() {
		_, e := AcquireRunLock(RunLockName)
		done <- e
	}()
	select {
	case e := <-done:
		require.Error(t, e, "锁被占用时再次获取必须 fast-fail")
	case <-time.After(2 * time.Second):
		t.Fatal("AcquireRunLock 未 fast-fail，疑似阻塞等待（违反单飞语义）")
	}

	// 释放后再次获取应成功。
	require.NoError(t, rel())
	rel2, err := AcquireRunLock(RunLockName)
	require.NoError(t, err, "释放后应能再次获取运行锁")
	require.NoError(t, rel2())

	// 锁路径与 Acquire 一致：<dir>/cfopt-sync-run.lock。
	_, statErr := os.Stat(lockPath(dir, RunLockName))
	assert.True(t, os.IsNotExist(statErr), "释放后锁目录应被清除")
}
