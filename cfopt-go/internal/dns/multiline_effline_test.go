package dns

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSyncMultiLine_UnifiedGlobalBestEffLine_ISPLines 验证生产 bug 修复点：
// 多线路（isp_lines）模式下，统一子域记录的「落盘线路（effLine）」与「读取线路」必须一致
// （均优先 DefaultLine，否则首线路）。这样既保证 global_best 文件的首行 IP 正确写入，
// 又保证后续同步能在同一线路读到该统一子域记录（避免 global_best 拿到 0 条 / 写到错误线路）。
//
// 设计：两条线路 default_line / unicom，DefaultLine=default_line；
//   - global_best 文件首行 9.9.9.9；
//   - default_line 的 IP 文件含 1.1.1.1，unicom 含 2.2.2.2。
//
// 断言：统一子域 "all" 必须落在线路 default_line 且值为 9.9.9.9；
//
//	线路 unicom 下不应出现 "all" 记录（证明落盘线路=DefaultLine 而非 unicom）。
func TestSyncMultiLine_UnifiedGlobalBestEffLine_ISPLines(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"default_line", "unicom"}
	m.subOf["default_line"] = "www"
	m.subOf["unicom"] = "www"
	m.ipFiles["default_line"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})
	m.ipFiles["unicom"] = writeIPFile(t, dir, "unicom.txt", []string{"2.2.2.2"})

	// 全局最优文件（首行 9.9.9.9）。
	bestFile := filepath.Join(dir, "best.iplist")
	require.NoError(t, os.WriteFile(bestFile, []byte("9.9.9.9|10|100|HKG\n"), 0o644))

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "global_best",
		GlobalBestFile:   bestFile,
		DefaultLine:      "default_line",
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	// 统一子域应落在 DefaultLine 线路，值为全局最优文件首行 IP。
	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "default_line")
	require.NoError(t, err)
	require.Len(t, recs, 1, "统一子域应落在 DefaultLine 线路")
	assert.Equal(t, "9.9.9.9", recs[0].Content, "global_best 模式应取全局最优文件首行 IP")

	// 关键一致性断言：统一子域绝不应落在非 DefaultLine 的线路（如 unicom）。
	recsUnicom, err := m.ListLineRecords(context.Background(), "example.com", "all", "unicom")
	require.NoError(t, err)
	assert.Empty(t, recsUnicom, "统一子域落盘线路必须为 DefaultLine（effLine），不应落到 unicom")
}

// TestSyncMultiLine_UnifiedFirstLineEffLine_ISPLines 验证 first_line 模式在 isp_lines 下：
// 统一子域 IP 取自 DefaultLine 线路的 IP 文件，且落盘线路=DefaultLine（两端一致）。
func TestSyncMultiLine_UnifiedFirstLineEffLine_ISPLines(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"default_line", "unicom"}
	m.subOf["default_line"] = "www"
	m.subOf["unicom"] = "www"
	m.ipFiles["default_line"] = writeIPFile(t, dir, "default.txt", []string{"1.1.1.1"})
	m.ipFiles["unicom"] = writeIPFile(t, dir, "unicom.txt", []string{"2.2.2.2"})

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "first_line",
		DefaultLine:      "default_line",
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	// 统一子域应落在 DefaultLine 线路，值为 default_line IP 文件的首 IP。
	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "default_line")
	require.NoError(t, err)
	require.Len(t, recs, 1, "first_line 模式统一子域应落在 DefaultLine 线路")
	assert.Equal(t, "1.1.1.1", recs[0].Content, "first_line 模式应取 DefaultLine 线路的 IP 文件首 IP")

	// 不应落到非 DefaultLine 线路。
	recsUnicom, err := m.ListLineRecords(context.Background(), "example.com", "all", "unicom")
	require.NoError(t, err)
	assert.Empty(t, recsUnicom, "统一子域落盘线路必须为 DefaultLine（effLine）")
}

// TestSyncMultiLine_UnifiedEffLine_EmptyDefaultLine 验证 DefaultLine 为空时：
// 落盘线路回退到首线路（Lines()[0]），且读取与落盘两端一致（统一子域可正确写入并被读到）。
func TestSyncMultiLine_UnifiedEffLine_EmptyDefaultLine(t *testing.T) {
	dir := t.TempDir()
	m := newMemLineProvider()
	m.lines = []string{"line_a", "line_b"}
	m.subOf["line_a"] = "www"
	m.subOf["line_b"] = "www"
	m.ipFiles["line_a"] = writeIPFile(t, dir, "a.txt", []string{"1.1.1.1"})
	m.ipFiles["line_b"] = writeIPFile(t, dir, "b.txt", []string{"2.2.2.2"})

	bestFile := filepath.Join(dir, "best.iplist")
	require.NoError(t, os.WriteFile(bestFile, []byte("9.9.9.9|10|100|HKG\n"), 0o644))

	res := SyncMultiLine(context.Background(), m, m, "example.com", 600, 0, MultiLineOptions{
		UnifiedSubDomain: "all",
		UnifiedMode:      "global_best",
		GlobalBestFile:   bestFile,
		DefaultLine:      "", // 空 → 回退首线路 line_a
		DeleteMode:       "unified-non-default",
	})
	require.NotNil(t, res)

	// 落盘线路应为首线路 line_a，值为全局最优文件首行 IP。
	recs, err := m.ListLineRecords(context.Background(), "example.com", "all", "line_a")
	require.NoError(t, err)
	require.Len(t, recs, 1, "DefaultLine 为空时应回退首线路 line_a")
	assert.Equal(t, "9.9.9.9", recs[0].Content)

	// 不应落到非首线路 line_b。
	recsB, err := m.ListLineRecords(context.Background(), "example.com", "all", "line_b")
	require.NoError(t, err)
	assert.Empty(t, recsB, "统一子域落盘线路必须为回退后的首线路，不应落到 line_b")
}
