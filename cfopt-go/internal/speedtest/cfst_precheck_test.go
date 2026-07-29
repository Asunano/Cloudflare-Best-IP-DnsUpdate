package speedtest

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

// TestCheckDownloadURLReachable_OK 验证：HTTP 200 且可读取响应体时返回可达。
func TestCheckDownloadURLReachable_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("dummy-bytes-for-download"))
	}))
	defer srv.Close()

	ok, err := checkDownloadURLReachable(context.Background(), srv.URL)
	assert.NoError(t, err)
	assert.True(t, ok, "200 + 可读响应应判定为可达")
}

// TestCheckDownloadURLReachable_404 验证：非 2xx/3xx 状态码视为不可达（不报错）。
func TestCheckDownloadURLReachable_404(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	ok, err := checkDownloadURLReachable(context.Background(), srv.URL)
	assert.NoError(t, err)
	assert.False(t, ok, "404 应判定为不可达")
}

// TestCheckDownloadURLReachable_Unreachable 验证：无法连接的地址返回不可达且不报错。
func TestCheckDownloadURLReachable_Unreachable(t *testing.T) {
	ok, err := checkDownloadURLReachable(context.Background(), "http://127.0.0.1:1/never")
	assert.NoError(t, err)
	assert.False(t, err == nil && ok, "不可达地址应返回 ok=false")
	assert.False(t, ok)
}

// TestCheckDownloadURLReachable_ContextCancel 验证：上下文取消时预检不挂死。
func TestCheckDownloadURLReachable_ContextCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	// 上下文取消后预检应快速返回（不挂死在 2s 的 server 上）。
	_, _ = checkDownloadURLReachable(ctx, srv.URL)
}
