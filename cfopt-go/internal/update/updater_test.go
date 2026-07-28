package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// sha256Hex 计算字节切片 SHA256 十六进制（测试辅助）。
func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// newTestUpdater 构造指向 httptest server 的 Updater（Insecure=true 允许本地 http）。
func newTestUpdater(srv *httptest.Server) *Updater {
	u := New("test/repo")
	u.APIBase = srv.URL
	u.Insecure = true
	return u
}

// TestParseVersion_IsNewer 验证版本解析与比较（容忍前导 v）。
func TestParseVersion_IsNewer(t *testing.T) {
	v, err := ParseVersion("v1.2.3")
	require.NoError(t, err)
	assert.Equal(t, "1.2.3", v.String())

	newer, err := IsNewer("1.3.0", "1.2.3")
	require.NoError(t, err)
	assert.True(t, newer)

	newer, err = IsNewer("1.2.3", "1.2.3")
	require.NoError(t, err)
	assert.False(t, newer, "同版本不应判为新")

	_, err = IsNewer("not-a-version", "1.0.0")
	assert.Error(t, err, "非法版本应报错")
}

// TestAssetName 验证资产命名与平台/扩展名一致（与 release.yml 上传命名对应）。
func TestAssetName(t *testing.T) {
	assert.Equal(t, "cfopt-linux-amd64", AssetName("linux", "amd64"))
	assert.Equal(t, "cfopt-windows-arm64.exe", AssetName("windows", "arm64"))
	assert.Equal(t, CurrentAssetName(), AssetName(runtime.GOOS, runtime.GOARCH))
}

// TestUpdater_DownloadRejectsNonTLS 安全红线：非 https 且未 Insecure 时必须拒绝。
func TestUpdater_DownloadRejectsNonTLS(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("binary"))
	}))
	defer srv.Close()

	u := New("test/repo") // Insecure=false（默认生产态）
	tmp := filepath.Join(t.TempDir(), "dl.tmp")
	_, err := u.download(context.Background(), srv.URL, tmp)
	require.Error(t, err, "非 TLS 源必须被拒绝")
	assert.Contains(t, err.Error(), "拒绝", "应给出明确拒绝原因")
}

// TestUpdater_DownloadAndReplace_Non200 安全红线：非 200 直接报错，绝不替换。
func TestUpdater_DownloadAndReplace_Non200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	u := newTestUpdater(srv)
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))

	info := &ReleaseInfo{
		Version: "1.0.0",
		Assets:  []Asset{{Name: "cfopt", URL: srv.URL + "/bin"}},
	}
	err := u.DownloadAndReplace(context.Background(), current, info, Options{Asset: "cfopt", NoVerify: true})
	require.Error(t, err, "HTTP 非 200 必须报错")

	// 当前二进制应保持不变。
	data, _ := os.ReadFile(current)
	assert.Equal(t, "old-binary", string(data), "替换失败不应改动当前二进制")
}

// TestUpdater_DownloadAndReplace_SHA256Mismatch 安全红线：哈希不符必须拒绝且清理临时文件。
func TestUpdater_DownloadAndReplace_SHA256Mismatch(t *testing.T) {
	binary := []byte("real-binary-content")
	mux := http.NewServeMux()
	mux.HandleFunc("/bin", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(binary)
	})
	mux.HandleFunc("/sums", func(w http.ResponseWriter, _ *http.Request) {
		// 故意写入错误哈希。
		_, _ = w.Write([]byte("deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  cfopt\n"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	u := newTestUpdater(srv)
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))

	info := &ReleaseInfo{
		Version: "1.0.0",
		Assets: []Asset{
			{Name: "cfopt", URL: srv.URL + "/bin", Size: int64(len(binary))},
			{Name: "SHA256SUMS", URL: srv.URL + "/sums"},
		},
	}
	err := u.DownloadAndReplace(context.Background(), current, info, Options{Asset: "cfopt"})
	require.Error(t, err, "SHA256 校验失败必须报错")
	assert.Contains(t, err.Error(), "SHA256", "错误应指出 SHA256 校验失败")

	// 当前二进制不变。
	data, _ := os.ReadFile(current)
	assert.Equal(t, "old-binary", string(data))

	// 临时文件应被清理。
	_, statErr := os.Stat(filepath.Join(dir, "cfopt.download"))
	assert.True(t, os.IsNotExist(statErr), "失败后应清理临时下载文件")
}

// TestUpdater_DownloadAndReplace_Success 正常路径：长度 + SHA256 通过 → 原子替换。
func TestUpdater_DownloadAndReplace_Success(t *testing.T) {
	binary := []byte("real-binary-content-v2")
	sums := fmt.Sprintf("%s  cfopt\n", sha256Hex(binary))
	mux := http.NewServeMux()
	mux.HandleFunc("/bin", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(binary)
	})
	mux.HandleFunc("/sums", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(sums))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	u := newTestUpdater(srv)
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary"), 0o755))

	info := &ReleaseInfo{
		Version: "1.0.0",
		Assets: []Asset{
			{Name: "cfopt", URL: srv.URL + "/bin", Size: int64(len(binary))},
			{Name: "SHA256SUMS", URL: srv.URL + "/sums"},
		},
	}
	err := u.DownloadAndReplace(context.Background(), current, info, Options{Asset: "cfopt"})
	require.NoError(t, err, "正常下载+校验应通过")

	// 当前二进制被替换。
	data, _ := os.ReadFile(current)
	assert.Equal(t, string(binary), string(data), "应原子替换为新二进制")

	// 旧版本备份为 cfopt.old。
	old, err := os.ReadFile(current + ".old")
	require.NoError(t, err, "应保留上一版本备份")
	assert.Equal(t, "old-binary", string(old))
}

// TestUpdater_Rollback 验证回滚：恢复 cfopt.old 为当前二进制。
func TestUpdater_Rollback(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("new-binary"), 0o755))
	require.NoError(t, os.WriteFile(current+".old", []byte("old-binary"), 0o755))

	require.NoError(t, Rollback(current))

	data, _ := os.ReadFile(current)
	assert.Equal(t, "old-binary", string(data), "回滚后应为旧版本")
}
