package update

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/geo"
)

// TestUpdater_DownloadProxyPrefix 验证：设置 ProxyPrefix 后，download 会将原始 https 链接
// 改写为「代理前缀 + 原始链接」形式（如 https://v4.gh-proxy.org/https://github.com/...）。
func TestUpdater_DownloadProxyPrefix(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = w.Write([]byte("binary"))
	}))
	defer srv.Close()

	u := New("test/repo")
	u.Insecure = true // 允许本地 httptest 的 http
	u.SetProxyPrefix(srv.URL + "/")

	// 模拟原始下载链接（不变量：此处为 github 的 https 链接）。
	origURL := "https://github.com/owner/repo/releases/download/v1.0.0/asset.zip"
	tmp := filepath.Join(t.TempDir(), "dl.tmp")
	n, err := u.download(context.Background(), origURL, tmp)
	require.NoError(t, err)
	assert.Equal(t, int64(len("binary")), n)
	// 请求路径应为「/https://github.com/...」，即前缀拼在原始链接前。
	assert.Equal(t, "/"+origURL, gotPath, "download 应将代理前缀拼到原始链接前")
}

// TestUpdater_ResolveAutoMirror_CN 验证：地区检测为中国时，自动将 ProxyPrefix 置为 ChinaMirrorProxy。
func TestUpdater_ResolveAutoMirror_CN(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"country_code":"CN"}`))
	}))
	defer srv.Close()

	orig := geo.APIURL
	geo.APIURL = srv.URL
	defer func() { geo.APIURL = orig }()

	u := New("test/repo")
	u.EnableAutoMirror = true
	u.ResolveAutoMirror(context.Background())
	assert.Equal(t, geo.ChinaMirrorProxy, u.ProxyPrefix, "CN 应启用 gh-proxy 前缀")
}

// TestUpdater_ResolveAutoMirror_NotCN 验证：非中国地区不启用镜像。
func TestUpdater_ResolveAutoMirror_NotCN(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"country_code":"US"}`))
	}))
	defer srv.Close()

	orig := geo.APIURL
	geo.APIURL = srv.URL
	defer func() { geo.APIURL = orig }()

	u := New("test/repo")
	u.EnableAutoMirror = true
	u.ResolveAutoMirror(context.Background())
	assert.Empty(t, u.ProxyPrefix, "非 CN 不应启用镜像")
}

// TestUpdater_ResolveAutoMirror_ExplicitMirrorWins 验证：已显式设置 Mirror 时不覆盖。
func TestUpdater_ResolveAutoMirror_ExplicitMirrorWins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"country_code":"CN"}`))
	}))
	defer srv.Close()

	orig := geo.APIURL
	geo.APIURL = srv.URL
	defer func() { geo.APIURL = orig }()

	u := New("test/repo")
	u.EnableAutoMirror = true
	u.SetMirror("https://example.com/mirror")
	u.ResolveAutoMirror(context.Background())
	assert.Empty(t, u.ProxyPrefix, "显式 Mirror 时不应设置 ProxyPrefix")
	assert.Equal(t, "https://example.com/mirror", u.Mirror)
}
