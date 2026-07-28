package dns

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ---------------------------------------------------------------------------
// 内存实现：LineResolver + LineAwareProvider（供 SyncMultiLine 单元测试）
// ---------------------------------------------------------------------------

type memLineProvider struct {
	lines   []string
	subOf   map[string]string // line -> subdomain
	ipFiles map[string]string // line -> ip 文件
	store   map[string][]Record
	nextID  int
}

func newMemLineProvider() *memLineProvider {
	return &memLineProvider{
		subOf:   map[string]string{},
		ipFiles: map[string]string{},
		store:   map[string][]Record{},
	}
}

func memKey(sub, line string) string { return sub + "|" + line }

func (m *memLineProvider) ResolveSubDomain(line string) string {
	if s, ok := m.subOf[line]; ok && s != "" {
		return s
	}
	return "sub"
}
func (m *memLineProvider) Lines() []string { return m.lines }
func (m *memLineProvider) IPFilesForLine(line string) []string {
	if f, ok := m.ipFiles[line]; ok && f != "" {
		return []string{f}
	}
	return nil
}
func (m *memLineProvider) ListLineRecords(_ context.Context, _ string, subDomain, line string) ([]Record, error) {
	k := memKey(subDomain, line)
	out := make([]Record, len(m.store[k]))
	copy(out, m.store[k])
	return out, nil
}
func (m *memLineProvider) UpsertLineRecord(_ context.Context, _ string, subDomain, line, value string, ttl int) error {
	k := memKey(subDomain, line)
	for i := range m.store[k] {
		if m.store[k][i].Content == value {
			m.store[k][i].TTL = ttl // 仅在 TTL 变化时覆盖（与 DNSPod 行为一致）
			return nil
		}
	}
	m.nextID++
	m.store[k] = append(m.store[k], Record{ID: fmt.Sprintf("r%d", m.nextID), Content: value, TTL: ttl, Line: line})
	return nil
}
func (m *memLineProvider) DeleteLineRecord(_ context.Context, _ string, recordID string) error {
	for k, recs := range m.store {
		for i, r := range recs {
			if r.ID == recordID {
				m.store[k] = append(recs[:i], recs[i+1:]...)
				return nil
			}
		}
	}
	return nil
}

// writeIPFile 写入纯文本 IP 文件（每行一个 IP），返回路径。
func writeIPFile(t *testing.T, dir, name string, ips []string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	content := ""
	for _, ip := range ips {
		content += ip + "\n"
	}
	require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	return p
}

// ---------------------------------------------------------------------------
// isLineDeletable
// ---------------------------------------------------------------------------

func TestIsLineDeletable(t *testing.T) {
	cases := []struct {
		mode      string
		line      string
		defaultLn string
		want      bool
	}{
		{"", "默认", "", false},          // 空/未知 → 安全默认 none
		{"none", "默认", "", false},      // none → 不删
		{"unified", "默认", "", false},   // unified → 仅统一子域可删，per-line 不删
		{"unified", "联通", "", false},   // unified → per-line 不删
		{"unified-non-default", "联通", "默认", true},    // 非默认线路可删
		{"unified-non-default", "默认", "默认", false},   // 默认线路受保护
		{"unified-non-default", "默认", "", true},        // 无 DefaultLine 指定 → 视为可删
	}
	for _, c := range cases {
		got := isLineDeletable(MultiLineOptions{DeleteMode: c.mode, DefaultLine: c.defaultLn}, c.line)
		assert.Equal(t, c.want, got, "DeleteMode=%q line=%q default=%q", c.mode, c.line, c.defaultLn)
	}
}

// ---------------------------------------------------------------------------
// SyncMultiLine
// ---------------------------------------------------------------------------

func TestSyncMultiLine_CreateMissing(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1", "2.2.2.2"})

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{})
	require.NotNil(t, res)
	assert.Equal(t, 2, res.Created, "应为两个新 IP 各创建一条记录")
	assert.Equal(t, 0, res.Deleted)
	assert.Equal(t, 0, res.Updated)

	recs, err := m.ListLineRecords(context.Background(), "example.com", "www", "默认")
	require.NoError(t, err)
	assert.Len(t, recs, 2)
}

func TestSyncMultiLine_DeleteExcessAndCreateMissing(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1", "8.8.8.8"})

	// 预置 3 条旧记录：1.1.1.1（保留）、2.2.2.2（删除）、3.3.3.3（删除）。
	k := memKey("www", "默认")
	m.store[k] = []Record{
		{ID: "old1", Content: "1.1.1.1", TTL: 600},
		{ID: "old2", Content: "2.2.2.2", TTL: 600},
		{ID: "old3", Content: "3.3.3.3", TTL: 600},
	}

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{DeleteMode: "unified-non-default"})
	require.NotNil(t, res)
	assert.Equal(t, 1, res.Created, "应新建 8.8.8.8")
	assert.Equal(t, 2, res.Deleted, "应删除 2.2.2.2 / 3.3.3.3")
	assert.Equal(t, 0, res.Updated)

	recs, _ := m.ListLineRecords(context.Background(), "example.com", "www", "默认")
	got := map[string]bool{}
	for _, r := range recs {
		got[r.Content] = true
	}
	assert.True(t, got["1.1.1.1"], "保留的 1.1.1.1 仍在")
	assert.True(t, got["8.8.8.8"], "新建的 8.8.8.8 存在")
	assert.False(t, got["2.2.2.2"], "2.2.2.2 已删")
	assert.False(t, got["3.3.3.3"], "3.3.3.3 已删")
}

func TestSyncMultiLine_SameSetRefreshesTTL(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1", "2.2.2.2"})

	k := memKey("www", "默认")
	m.store[k] = []Record{
		{ID: "a", Content: "1.1.1.1", TTL: 60},  // TTL 不同 -> 刷新
		{ID: "b", Content: "2.2.2.2", TTL: 600}, // 已是目标 TTL -> 不变
	}

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{DeleteMode: "unified-non-default"})
	require.NotNil(t, res)
	assert.Equal(t, 1, res.Updated, "仅 TTL 变化的一条应刷新")
	assert.Equal(t, 0, res.Created)
	assert.Equal(t, 0, res.Deleted, "集合相同不应有任何删除")

	recs, _ := m.ListLineRecords(context.Background(), "example.com", "www", "默认")
	require.Len(t, recs, 2)
	assert.Equal(t, 600, recs[0].TTL)
	assert.Equal(t, 600, recs[1].TTL)
}

func TestSyncMultiLine_DeleteModeNoneKeepsExcess(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})

	k := memKey("www", "默认")
	m.store[k] = []Record{{ID: "old1", Content: "9.9.9.9", TTL: 600}} // 多余但 DeleteMode=none → 保留

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{DeleteMode: "none"})
	require.NotNil(t, res)
	assert.Equal(t, 0, res.Deleted, "none 模式不删任何记录（固化）")
	assert.Equal(t, 1, res.Created, "仍应创建缺失的 1.1.1.1")

	recs, _ := m.ListLineRecords(context.Background(), "example.com", "www", "默认")
	assert.Len(t, recs, 2, "none 模式旧记录 9.9.9.9 应保留")
}

func TestSyncMultiLine_UnifiedSubDomain(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		DefaultLine:      "默认",
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	// 统一子域应写入 DefaultLine 线路的 IP（首条 = 1.1.1.1）。
	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "默认")
	require.NoError(t, err)
	require.Len(t, recs, 1)
	assert.Equal(t, "1.1.1.1", recs[0].Content)
}

func TestSyncMultiLine_NoValidIPSkipsLine(t *testing.T) {
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	// 不设置 ipFiles → 无 IP → 该线路跳过，不应报错。

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{})
	require.NotNil(t, res)
	assert.Equal(t, 0, res.Created)
	assert.Empty(t, res.Errors, "无有效 IP 只跳过，不计入错误")
}

// TestSyncMultiLine_UnifiedGlobalBest 验证 unified_mode=global_best 时，统一子域取全局最优文件首行 IP。
func TestSyncMultiLine_UnifiedGlobalBest(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})

	// 全局最优文件（首行 9.9.9.9）。
	bestFile := filepath.Join(dir, "best.iplist")
	require.NoError(t, os.WriteFile(bestFile, []byte("9.9.9.9|10|100|HKG\n"), 0o644))

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "global_best",
		GlobalBestFile:   bestFile,
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "默认")
	require.NoError(t, err)
	require.Len(t, recs, 1)
	assert.Equal(t, "9.9.9.9", recs[0].Content, "global_best 模式应取全局最优文件首行 IP")
}

// TestSyncMultiLine_UnifiedGlobalBestFallback 验证 global_best 文件缺失/空时回退首线路 IP。
func TestSyncMultiLine_UnifiedGlobalBestFallback(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "global_best",
		GlobalBestFile:   filepath.Join(dir, "missing.iplist"),
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "默认")
	require.NoError(t, err)
	require.Len(t, recs, 1)
	assert.Equal(t, "1.1.1.1", recs[0].Content, "global_best 缺失应回退首线路 IP")
}

// TestSyncMultiLine_UnifiedFirstLine 验证默认（first_line）模式仍取 DefaultLine/首线路 IP。
func TestSyncMultiLine_UnifiedFirstLine(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"默认"}
	m.subOf["默认"] = "www"
	m.ipFiles["默认"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})

	// 即便存在全局最优文件，first_line 模式也不应读取它。
	bestFile := filepath.Join(dir, "best.iplist")
	require.NoError(t, os.WriteFile(bestFile, []byte("9.9.9.9|10|100|HKG\n"), 0o644))

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "first_line",
		GlobalBestFile:   bestFile,
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "默认")
	require.NoError(t, err)
	require.Len(t, recs, 1)
	assert.Equal(t, "1.1.1.1", recs[0].Content, "first_line 模式应取首线路 IP，而非全局最优")
}
