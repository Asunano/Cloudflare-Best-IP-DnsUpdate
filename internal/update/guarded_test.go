package update

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRunGuarded_LoopGuardBlocks 当连续失败计数达到阈值时，RunGuarded 必须直接返回 ErrUpdateLoop，
// 且不发起任何下载（当前二进制保持不变）。
func TestRunGuarded_LoopGuardBlocks(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))
	// 预置计数达到阈值。
	require.NoError(t, os.WriteFile(failureCountPath(current), []byte("3"), 0o644))

	var hit bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hit = true
		_, _ = w.Write([]byte("new-binary"))
	}))
	defer srv.Close()
	u := newTestUpdater(srv)
	info := &ReleaseInfo{Version: "1.0.0", Assets: []Asset{{Name: "cfopt", URL: srv.URL + "/bin"}}}

	err := RunGuarded(u, context.Background(), current, info, Options{Asset: "cfopt", NoVerify: true})
	require.Error(t, err, "达到阈值必须触发防循环保护")
	assert.ErrorIs(t, err, ErrUpdateLoop, "应返回 ErrUpdateLoop")
	assert.False(t, hit, "触发保护后不应再发起下载")
	data, _ := os.ReadFile(current)
	assert.Equal(t, "old-binary", string(data), "触发保护不应替换二进制")
}

// TestRunGuarded_FailureBumpsCount 失败时应累加连续失败计数。
func TestRunGuarded_FailureBumpsCount(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	u := newTestUpdater(srv)
	info := &ReleaseInfo{Version: "1.0.0", Assets: []Asset{{Name: "cfopt", URL: srv.URL + "/bin"}}}

	opts := Options{Asset: "cfopt", NoVerify: true}
	require.Error(t, RunGuarded(u, context.Background(), current, info, opts))
	assert.Equal(t, 1, loadFailureCount(failureCountPath(current)), "首次失败计数应为 1")

	require.Error(t, RunGuarded(u, context.Background(), current, info, opts))
	assert.Equal(t, 2, loadFailureCount(failureCountPath(current)), "二次失败计数应为 2")
}

// TestRunGuarded_SuccessResetsCount 成功更新后应清零计数文件。
func TestRunGuarded_SuccessResetsCount(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))
	// 预置一个历史失败计数。
	require.NoError(t, os.WriteFile(failureCountPath(current), []byte("2"), 0o644))

	binary := []byte("real-binary-content-v2")
	sums := fmt.Sprintf("%s  cfopt\n", sha256Hex(binary))
	mux := http.NewServeMux()
	mux.HandleFunc("/bin", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(binary) })
	mux.HandleFunc("/sums", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(sums)) })
	srv := httptest.NewServer(mux)
	defer srv.Close()
	u := newTestUpdater(srv)
	info := &ReleaseInfo{Version: "1.0.0", Assets: []Asset{
		{Name: "cfopt", URL: srv.URL + "/bin", Size: int64(len(binary))},
		{Name: "SHA256SUMS", URL: srv.URL + "/sums"},
	}}

	require.NoError(t, RunGuarded(u, context.Background(), current, info, Options{Asset: "cfopt"}))
	_, statErr := os.Stat(failureCountPath(current))
	assert.True(t, os.IsNotExist(statErr), "成功更新应清零计数文件")

	data, _ := os.ReadFile(current)
	assert.Equal(t, string(binary), string(data), "应原子替换为新二进制")
}
