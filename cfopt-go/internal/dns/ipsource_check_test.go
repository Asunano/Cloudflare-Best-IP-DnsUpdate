package dns

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// 写一个 .txt IP 源文件（每行一个 IP，TXT 解析器按行计数）。
func mkIPFile(t *testing.T, dir, name string, ips ...string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	content := strings.Join(ips, "\n") + "\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	return p
}

// TestCheckIPSources_CountChangeWarns 验证：IP 数量相对上次 (.count) 变化 >50% 时发出严重警告。
func TestCheckIPSources_CountChangeWarns(t *testing.T) {
	dir := t.TempDir()
	f := mkIPFile(t, dir, "ip.txt", "1.1.1.1", "2.2.2.2") // 本次 2 个
	// 上次记录为 10 个 → 变化 (2-10)/10 = 80% > 50%
	require.NoError(t, os.WriteFile(f+".count", []byte("10"), 0o644))

	warns := CheckIPSources([]string{f}, IPSourceCheckOpts{})
	require.Len(t, warns, 1, "应产生 1 条数量剧变警告")
	assert.Contains(t, warns[0], "严重警告")
	assert.Contains(t, warns[0], "50%")
}

// TestCheckIPSources_NoWarnWhenStable 验证：数量无变化时无警告（且仍更新 .count）。
func TestCheckIPSources_NoWarnWhenStable(t *testing.T) {
	dir := t.TempDir()
	f := mkIPFile(t, dir, "ip.txt", "1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4", "5.5.5.5") // 本次 5 个
	require.NoError(t, os.WriteFile(f+".count", []byte("5"), 0o644))

	warns := CheckIPSources([]string{f}, IPSourceCheckOpts{})
	assert.Empty(t, warns, "数量未变不应有警告")

	// .count 应被更新为本次数量 5。
	data, err := os.ReadFile(f + ".count")
	require.NoError(t, err)
	assert.Equal(t, "5", strings.TrimSpace(string(data)))
}

// TestCheckIPSources_ExpiryWarns 验证：IP 源文件 mtime 超过 48h 时发出过期警告。
func TestCheckIPSources_ExpiryWarns(t *testing.T) {
	dir := t.TempDir()
	f := mkIPFile(t, dir, "ip.txt", "1.1.1.1")
	past := time.Now().Add(-49 * time.Hour)
	require.NoError(t, os.Chtimes(f, past, past))

	warns := CheckIPSources([]string{f}, IPSourceCheckOpts{})
	require.Len(t, warns, 1, "应产生 1 条过期警告")
	assert.Contains(t, warns[0], "已过期")
}

// TestCheckIPSources_FreshNoExpiry 验证：mtime 在阈值内不报过期。
func TestCheckIPSources_FreshNoExpiry(t *testing.T) {
	dir := t.TempDir()
	f := mkIPFile(t, dir, "ip.txt", "1.1.1.1")

	warns := CheckIPSources([]string{f}, IPSourceCheckOpts{})
	for _, w := range warns {
		assert.NotContains(t, w, "已过期")
	}
}

// TestCheckIPSources_SkipsMissing 验证：文件不存在时静默跳过（不报错、无警告）。
func TestCheckIPSources_SkipsMissing(t *testing.T) {
	warns := CheckIPSources([]string{filepath.Join(t.TempDir(), "nope.txt")}, IPSourceCheckOpts{})
	assert.Empty(t, warns)
}
