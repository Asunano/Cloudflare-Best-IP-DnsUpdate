package speedtest

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// TestResolveIPFile_ConfiguredMissing 验证：当配置了 cfst.ip_file 但文件不存在时，
// resolveIPFile 返回错误（且错误信息包含 ip_file / 不存在）。不发网络。
func TestResolveIPFile_ConfiguredMissing(t *testing.T) {
	cfg := &config.CFIPConfig{
		CFST: config.CFSTConfig{IPFile: "/no/such/file"},
	}
	_, err := (&CFSTTester{}).resolveIPFile(context.Background(), cfg, t.TempDir())
	require.Error(t, err, "配置了不存在的 ip_file 时应返回错误")
	assert.Contains(t, err.Error(), "ip_file")
	assert.Contains(t, err.Error(), "不存在")
}

// TestResolveIPFile_ConfiguredExists 验证：配置了存在 ip_file 时，直接返回该路径、不报错、不发网络。
func TestResolveIPFile_ConfiguredExists(t *testing.T) {
	dir := t.TempDir()
	ipPath := filepath.Join(dir, "myip.txt")
	require.NoError(t, os.WriteFile(ipPath, []byte("203.0.113.0/24\n"), 0o644))

	cfg := &config.CFIPConfig{
		CFST: config.CFSTConfig{IPFile: ipPath},
	}
	got, err := (&CFSTTester{}).resolveIPFile(context.Background(), cfg, t.TempDir())
	require.NoError(t, err, "配置了存在的 ip_file 时不应报错")
	assert.Equal(t, ipPath, got)
}

// TestResolveIPFile_DefaultCached 验证：ip_file 为空且 outputDir 下已存在 ip.txt 时，
// 直接复用缓存文件（不发网络）。
func TestResolveIPFile_DefaultCached(t *testing.T) {
	dir := t.TempDir()
	ipPath := filepath.Join(dir, "ip.txt")
	require.NoError(t, os.WriteFile(ipPath, []byte("203.0.113.0/24\n"), 0o644))

	cfg := &config.CFIPConfig{} // IPFile 默认空
	got, err := (&CFSTTester{}).resolveIPFile(context.Background(), cfg, dir)
	require.NoError(t, err, "默认 ip.txt 已缓存时不应报错")
	assert.Equal(t, ipPath, got)
}

// TestFetchCloudflareRanges 验证：fetchCloudflareRanges 能从两个地址拉取并合并写入 dest，
// 文件内容同时包含 IPv4 与 IPv6 段。用 httptest server 替换官方地址（不发真实外网）。
func TestFetchCloudflareRanges(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ips-v4", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("203.0.113.0/24\n"))
	})
	mux.HandleFunc("/ips-v6", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("2001:db8::/32\n"))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	// 临时把拉取地址替换为本地 server，用 defer 还原。
	orig := cloudflareRangeURLs
	cloudflareRangeURLs = []string{
		server.URL + "/ips-v4",
		server.URL + "/ips-v6",
	}
	defer func() { cloudflareRangeURLs = orig }()

	dest := filepath.Join(t.TempDir(), "ip.txt")
	require.NoError(t, fetchCloudflareRanges(context.Background(), dest))

	data, err := os.ReadFile(dest)
	require.NoError(t, err, "目标文件应被写入")
	content := string(data)
	assert.Contains(t, content, "203.0.113.0/24", "应含 IPv4 段")
	assert.Contains(t, content, "2001:db8::/32", "应含 IPv6 段")
}

// TestFetchCloudflareRanges_HTTPError 验证：任一地址返回非 200 时 fetchCloudflareRanges 报错。
func TestFetchCloudflareRanges_HTTPError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ips-v4", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	mux.HandleFunc("/ips-v6", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("2001:db8::/32\n"))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	orig := cloudflareRangeURLs
	cloudflareRangeURLs = []string{
		server.URL + "/ips-v4",
		server.URL + "/ips-v6",
	}
	defer func() { cloudflareRangeURLs = orig }()

	dest := filepath.Join(t.TempDir(), "ip.txt")
	err := fetchCloudflareRanges(context.Background(), dest)
	require.Error(t, err, "HTTP 非 200 时应返回错误")
}

// TestBuildCmd_NoIPFileFlag 验证：ip_file 为空时 buildCmd 不再拼装 -c（IP 分支已移出 buildCmd）。
func TestBuildCmd_NoIPFileFlag(t *testing.T) {
	tester := &CFSTTester{binPath: "dummy"}
	cfg := &config.CFIPConfig{} // IPFile 默认空
	args := tester.buildCmd(cfg, "o.csv")
	assert.NotContains(t, args, "-c",
		"buildCmd 不应再拼装 IP 文件分支（-c 改由 Run 通过 resolveIPFile 解析后追加）")
}
