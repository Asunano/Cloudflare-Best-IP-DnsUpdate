package cfst

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// sha256Hex 计算字节切片 SHA256 十六进制（测试辅助）。
func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// makeZip 生成含 innerName 条目的 zip 字节。
func makeZip(t *testing.T, content []byte, innerName string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create(innerName)
	require.NoError(t, err)
	_, err = w.Write(content)
	require.NoError(t, err)
	require.NoError(t, zw.Close())
	return buf.Bytes()
}

// makeTarGz 生成含 innerName 条目的 tar.gz 字节。
func makeTarGz(t *testing.T, content []byte, innerName string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gw)
	hdr := &tar.Header{Name: innerName, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}
	require.NoError(t, tw.WriteHeader(hdr))
	_, err := tw.Write(content)
	require.NoError(t, err)
	require.NoError(t, tw.Close())
	require.NoError(t, gw.Close())
	return buf.Bytes()
}

// fakeAsset 模拟一个 release 资产。
type fakeAsset struct {
	name   string
	digest string
	bytes  []byte
}

// serveReleaseAssets 启动 httptest 服务，模拟 GitHub release API（带 digest）与资产下载。
func serveReleaseAssets(t *testing.T, assets []fakeAsset) *httptest.Server {
	t.Helper()
	var srv *httptest.Server
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/XIU2/CloudflareSpeedTest/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		var sb strings.Builder
		sb.WriteString(`{"tag_name":"v2.3.5","assets":[`)
		for i, a := range assets {
			if i > 0 {
				sb.WriteString(",")
			}
			dl := srv.URL + "/asset/" + a.name
			sb.WriteString(fmt.Sprintf(`{"name":%q,"browser_download_url":%q,"size":%d,"digest":%q}`, a.name, dl, len(a.bytes), a.digest))
		}
		sb.WriteString(`]}`)
		_, _ = w.Write([]byte(sb.String()))
	})
	mux.HandleFunc("/asset/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/asset/")
		for _, a := range assets {
			if a.name == name {
				_, _ = w.Write(a.bytes)
				return
			}
		}
		http.NotFound(w, r)
	})
	srv = httptest.NewServer(mux)
	return srv
}

// TestFetch_WindowsZip 验证 Windows 平台从 zip 下载、SHA256 校验通过并落盘到 assets/cfst/cfst.exe。
func TestFetch_WindowsZip(t *testing.T) {
	content := []byte("fake-cfst-windows-binary")
	assetBytes := makeZip(t, content, "cfst.exe")
	digest := "sha256:" + sha256Hex(assetBytes)

	srv := serveReleaseAssets(t, []fakeAsset{
		{name: "cfst_windows_amd64.zip", digest: digest, bytes: assetBytes},
	})
	defer srv.Close()

	dest := t.TempDir()
	path, err := Fetch(context.Background(), CFSTFetchOptions{
		Repo: "XIU2/CloudflareSpeedTest", Goos: "windows", Goarch: "amd64",
		DestDir: dest, Insecure: true, APIBase: srv.URL,
	})
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(dest, "cfst.exe"), path, "应落盘为 cfst.exe")

	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, content, got, "落盘内容应与包内二进制一致")
}

// TestFetch_LinuxTarGz 验证 Linux 平台从 tar.gz 下载、SHA256 校验通过并落盘到 assets/cfst/cfst。
func TestFetch_LinuxTarGz(t *testing.T) {
	content := []byte("fake-cfst-linux-binary")
	assetBytes := makeTarGz(t, content, "cfst")
	digest := "sha256:" + sha256Hex(assetBytes)

	srv := serveReleaseAssets(t, []fakeAsset{
		{name: "cfst_linux_amd64.tar.gz", digest: digest, bytes: assetBytes},
	})
	defer srv.Close()

	dest := t.TempDir()
	path, err := Fetch(context.Background(), CFSTFetchOptions{
		Repo: "XIU2/CloudflareSpeedTest", Goos: "linux", Goarch: "amd64",
		DestDir: dest, Insecure: true, APIBase: srv.URL,
	})
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(dest, "cfst"), path, "应落盘为 cfst")

	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, content, got)
}

// TestFetch_SHA256Mismatch 验证 SHA256 校验失败时不落盘并返回错误。
func TestFetch_SHA256Mismatch(t *testing.T) {
	content := []byte("fake-cfst-windows-binary")
	assetBytes := makeZip(t, content, "cfst.exe")
	// 故意使用错误摘要。
	badDigest := "sha256:" + strings.Repeat("0", 64)

	srv := serveReleaseAssets(t, []fakeAsset{
		{name: "cfst_windows_amd64.zip", digest: badDigest, bytes: assetBytes},
	})
	defer srv.Close()

	dest := t.TempDir()
	_, err := Fetch(context.Background(), CFSTFetchOptions{
		Repo: "XIU2/CloudflareSpeedTest", Goos: "windows", Goarch: "amd64",
		DestDir: dest, Insecure: true, APIBase: srv.URL,
	})
	require.Error(t, err, "SHA256 校验失败必须报错")
	assert.Contains(t, err.Error(), "SHA256", "错误应指出 SHA256 校验失败")

	// 绝不落盘。
	_, statErr := os.Stat(filepath.Join(dest, "cfst.exe"))
	assert.True(t, os.IsNotExist(statErr), "校验失败不应落盘 cfst.exe")
}

// TestFetch_OldVariantExcluded 验证 _old 后缀资产被排除，命中正常资产。
func TestFetch_OldVariantExcluded(t *testing.T) {
	content := []byte("fake-cfst-windows-binary")
	good := makeZip(t, content, "cfst.exe")
	goodDigest := "sha256:" + sha256Hex(good)
	// _old 变体（内容不同），不应被选用。
	oldBytes := makeZip(t, []byte("OLD-BINARY-DIFFERENT"), "cfst.exe")
	oldDigest := "sha256:" + sha256Hex(oldBytes)

	srv := serveReleaseAssets(t, []fakeAsset{
		{name: "cfst_windows_amd64_old.zip", digest: oldDigest, bytes: oldBytes},
		{name: "cfst_windows_amd64.zip", digest: goodDigest, bytes: good},
	})
	defer srv.Close()

	dest := t.TempDir()
	path, err := Fetch(context.Background(), CFSTFetchOptions{
		Repo: "XIU2/CloudflareSpeedTest", Goos: "windows", Goarch: "amd64",
		DestDir: dest, Insecure: true, APIBase: srv.URL,
	})
	require.NoError(t, err)
	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, content, got, "应命中非 _old 资产")
}

// TestFetch_UnsupportedArch 验证不支持的架构被拒绝。
func TestFetch_UnsupportedArch(t *testing.T) {
	_, err := Fetch(context.Background(), CFSTFetchOptions{
		Goos: "windows", Goarch: "riscv64", Insecure: true,
	})
	require.Error(t, err, "riscv64 不应被支持")
}
