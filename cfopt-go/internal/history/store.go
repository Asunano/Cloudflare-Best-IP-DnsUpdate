// Package history 提供历史记录读写能力（JSON Lines 格式，追加写、倒序读）。
// 写时用 common.fslock 跨进程加锁，保证并发安全。
package history

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"cfopt/internal/common"
)

// HistoryEntry 单条历史记录。
type HistoryEntry struct {
	Timestamp time.Time `json:"ts"`      // 发生时间
	Action    string    `json:"action"`  // 动作标识，如 "speedtest"/"sync.cf"/"sync.dnspod"
	Detail    string    `json:"detail"`  // 摘要详情（计数 / 错误原因等）
	Success   bool      `json:"success"` // 是否成功
}

// HistoryStore 历史记录读写接口。
type HistoryStore interface {
	// Append 追加一条历史记录。
	Append(e HistoryEntry) error
	// ReadLatest 倒序返回最近 n 条记录（最新在前）；n<=0 返回全部。
	ReadLatest(n int) ([]HistoryEntry, error)
}

// JSONLStore 基于 JSON Lines 的历史存储实现。
// 追加写（O_APPEND），读时整体解析后倒序；写时先由 s.mu（同进程）串行化，
// 再用 fslock 原子目录锁（跨进程）保证并发安全，并对抢锁失败做有限退避重试。
type JSONLStore struct {
	path string
	mu   sync.Mutex // 同进程 goroutine 串行化；跨进程安全仍由下方 fslock 重试保证
}

// NewJSONLStore 构造 JSONLStore。path 为历史文件路径，如 ./assets/data/history.jsonl。
func NewJSONLStore(path string) *JSONLStore {
	return &JSONLStore{path: path}
}

// Append 追加一条历史记录（JSON Lines 一行一个对象），写时加跨进程锁。
func (s *JSONLStore) Append(e HistoryEntry) error {
	// 同进程串行化：保证同一进程内只有一个 goroutine 进入写区。
	s.mu.Lock()
	defer s.mu.Unlock()

	if e.Timestamp.IsZero() {
		e.Timestamp = time.Now()
	}

	// 跨进程锁采用有限重试：本进程内已由 s.mu 串行化，此处仅在极端的跨进程竞争时退避重试，
	// 不改变 common.Acquire 的 fail-fast 语义（守护进程单实例守卫）。
	var rel common.ReleaseFunc
	var acqErr error
	for attempt := 0; attempt < 20; attempt++ {
		rel, acqErr = common.Acquire("history")
		if acqErr == nil {
			break
		}
		time.Sleep(time.Duration(20*(attempt+1)) * time.Millisecond)
	}
	if acqErr != nil {
		return common.Wrap("history:append:lock", acqErr)
	}
	defer func() { _ = rel() }()

	if dir := filepath.Dir(s.path); dir != "" {
		if mkErr := os.MkdirAll(dir, 0o755); mkErr != nil {
			return common.Wrap("history:append:mkdir", mkErr)
		}
	}
	f, err := os.OpenFile(s.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return common.Wrap("history:append:open", err)
	}
	defer func() { _ = f.Close() }()

	enc := json.NewEncoder(f)
	if err := enc.Encode(e); err != nil {
		return common.Wrap("history:append:encode", err)
	}
	return nil
}

// ReadLatest 倒序返回最近 n 条历史记录（最新在前）。n<=0 返回全部。
// 文件不存在时返回空切片与 nil 错误。
func (s *JSONLStore) ReadLatest(n int) ([]HistoryEntry, error) {
	f, err := os.Open(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, common.Wrap("history:read:open", err)
	}
	defer func() { _ = f.Close() }()

	var entries []HistoryEntry
	dec := json.NewDecoder(f)
	for {
		var e HistoryEntry
		if dErr := dec.Decode(&e); dErr != nil {
			if dErr == io.EOF {
				break
			}
			// 单行损坏时停止解析已读部分，避免整体失败
			common.Warn("history:read: 解析一行失败，已停止", "err", dErr.Error())
			break
		}
		entries = append(entries, e)
	}

	// 倒序：最新在前
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].Timestamp.After(entries[j].Timestamp)
	})
	if n > 0 && len(entries) > n {
		entries = entries[:n]
	}
	return entries, nil
}

// 编译期接口实现断言。
var _ HistoryStore = (*JSONLStore)(nil)
