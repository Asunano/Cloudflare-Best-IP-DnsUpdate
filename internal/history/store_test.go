package history

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/common"
)

// setupLock 将进程锁根目录指向临时目录，避免测试在包目录生成 ./locks。
func setupLock(t *testing.T) {
	t.Helper()
	common.SetLockDir(t.TempDir())
}

// TestJSONLStore_AppendThenReadLatest 验证 Append 后 ReadLatest 倒序返回，n 限制生效。
func TestJSONLStore_AppendThenReadLatest(t *testing.T) {
	setupLock(t)
	store := NewJSONLStore(filepath.Join(t.TempDir(), "history.jsonl"))

	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	require.NoError(t, store.Append(HistoryEntry{Timestamp: base, Action: "a", Detail: "first"}))
	require.NoError(t, store.Append(HistoryEntry{Timestamp: base.Add(time.Second), Action: "b", Detail: "second"}))
	require.NoError(t, store.Append(HistoryEntry{Timestamp: base.Add(2 * time.Second), Action: "c", Detail: "third"}))

	// 倒序：最新(c)在前
	all, err := store.ReadLatest(0)
	require.NoError(t, err)
	require.Len(t, all, 3)
	assert.Equal(t, "c", all[0].Action)
	assert.Equal(t, "b", all[1].Action)
	assert.Equal(t, "a", all[2].Action)

	// n=2 仅返回最近 2 条
	latest2, err := store.ReadLatest(2)
	require.NoError(t, err)
	require.Len(t, latest2, 2)
	assert.Equal(t, "c", latest2[0].Action)
	assert.Equal(t, "b", latest2[1].Action)

	// n=1 仅返回最新
	latest1, err := store.ReadLatest(1)
	require.NoError(t, err)
	require.Len(t, latest1, 1)
	assert.Equal(t, "c", latest1[0].Action)
}

// TestJSONLStore_ZeroTimestampFilled 验证未设 Timestamp 时由 Append 自动填充。
func TestJSONLStore_ZeroTimestampFilled(t *testing.T) {
	setupLock(t)
	store := NewJSONLStore(filepath.Join(t.TempDir(), "h2.jsonl"))
	require.NoError(t, store.Append(HistoryEntry{Action: "x"}))
	got, err := store.ReadLatest(1)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.False(t, got[0].Timestamp.IsZero(), "Append 应自动填充 Timestamp")
}

// TestJSONLStore_ReadMissingFile 验证文件不存在时返回空切片与 nil 错误（不报错）。
func TestJSONLStore_ReadMissingFile(t *testing.T) {
	setupLock(t)
	store := NewJSONLStore(filepath.Join(t.TempDir(), "does_not_exist.jsonl"))
	got, err := store.ReadLatest(0)
	require.NoError(t, err)
	assert.Empty(t, got)
}

// TestJSONLStore_ConcurrentAppend 验证并发 Append 安全：所有写入成功且无丢失。
//
// 注意：本测试断言「并发安全」这一需求（全部成功且条数=G）。
// 若本地运行失败（出现 "fslock:acquire" 类错误），即暴露 common.Acquire 在锁竞争时
// 直接返回错误而非阻塞等待的并发缺陷——详见交付报告「发现的源码级问题」。
func TestJSONLStore_ConcurrentAppend(t *testing.T) {
	setupLock(t)
	store := NewJSONLStore(filepath.Join(t.TempDir(), "concurrent.jsonl"))

	const G = 20
	var wg sync.WaitGroup
	errs := make([]error, G)
	for i := 0; i < G; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = store.Append(HistoryEntry{Action: fmt.Sprintf("a-%d", i)})
		}(i)
	}
	wg.Wait()

	for i, e := range errs {
		require.NoErrorf(t, e, "并发 Append #%d 不应失败", i)
	}

	got, err := store.ReadLatest(0)
	require.NoError(t, err)
	assert.Len(t, got, G, "并发写入后不应有丢失")
}
