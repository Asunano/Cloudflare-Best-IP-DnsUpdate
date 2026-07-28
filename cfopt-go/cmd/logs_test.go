package cmd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// captureStdout 将 os.Stdout 重定向到管道并返回读取函数（测试结束后恢复）。
func captureStdout(t *testing.T) func() string {
	t.Helper()
	r, w, err := os.Pipe()
	require.NoError(t, err)
	old := os.Stdout
	os.Stdout = w
	return func() string {
		_ = w.Close()
		os.Stdout = old
		out, _ := io.ReadAll(r)
		return string(out)
	}
}

// TestTailLines 验证取末尾 N 行。
func TestTailLines(t *testing.T) {
	lines := []string{"a", "b", "c", "d"}
	assert.Equal(t, []string{"c", "d"}, tailLines(lines, 2))
	assert.Equal(t, lines, tailLines(lines, 0), "n<=0 返回全部")
	assert.Equal(t, lines, tailLines(lines, 99), "n>=长度 返回全部")
}

// TestLevelRankInLine 验证从 slog 文本行提取级别数值。
func TestLevelRankInLine(t *testing.T) {
	assert.Equal(t, 3, levelRankInLine("level=INFO msg=hello time=2026"))
	assert.Equal(t, 4, levelRankInLine("level=DEBUG msg=x"))
	assert.Equal(t, 1, levelRankInLine("level=ERROR msg=fail"))
	assert.Equal(t, 0, levelRankInLine("msg=hello time=2026"), "无 level= 字段返回 0")
}

// TestFilterByLevel 验证级别过滤（rank 越小越严重：ERROR=1 WARN=2 INFO=3 DEBUG=4）。
// --level info 保留 info/warn/error，--level error 仅保留 error。无 level 行被跳过。
func TestFilterByLevel(t *testing.T) {
	lines := []string{
		"level=DEBUG msg=d",
		"level=INFO msg=i",
		"level=WARN msg=w",
		"level=ERROR msg=e",
		"plain line without level",
	}
	got := filterByLevel(lines, "info")
	assert.Equal(t, []string{"level=INFO msg=i", "level=WARN msg=w", "level=ERROR msg=e"}, got)

	got = filterByLevel(lines, "error")
	assert.Equal(t, []string{"level=ERROR msg=e"}, got)
}

// TestRunLogsFile_ReadsAndFilters 集成验证：写入临时日志文件，按 tail/level 过滤后正确输出。
func TestRunLogsFile_ReadsAndFilters(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, "logs")
	require.NoError(t, os.MkdirAll(logDir, 0o755))
	logPath := filepath.Join(logDir, "cfopt.log")
	content := strings.Join([]string{
		"level=INFO msg=start",
		"level=DEBUG msg=detail",
		"level=ERROR msg=boom",
		"", // 末尾空行应被忽略
	}, "\n")
	require.NoError(t, os.WriteFile(logPath, []byte(content), 0o644))

	// 仅 ERROR。
	get := captureStdout(t)
	err := runLogsFile(dir, 50, "error")
	require.NoError(t, err)
	out := get()
	assert.Contains(t, out, "level=ERROR msg=boom")
	assert.NotContains(t, out, "level=INFO")
	assert.NotContains(t, out, "level=DEBUG")
}

// TestRunLogsFile_MissingFile 日志文件不存在时应返回友好错误。
func TestRunLogsFile_MissingFile(t *testing.T) {
	err := runLogsFile(t.TempDir(), 50, "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "日志文件不存在")
}
