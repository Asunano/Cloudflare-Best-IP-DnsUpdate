package update

// 二次检测补充测试（独立视角）：端到端验证 P0-3「update 安全红线」。
//
// 现有 TestUpdater_DownloadAndReplace_SHA256Mismatch 已验证「报错 + 清临时文件 + 当前二进制不变」；
// 本测试在此基础上独立追加一条更关键的不变量：SHA256 校验失败时，绝不产生 .old 备份文件，
// 证明原子 os.Rename（当前→备份、临时→当前）从未发生，不存在“半替换”的中间状态。

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestUpdater_DownloadAndReplace_WrongChecksumNoBackup 注入错误 SHA256，验证：
// （1）报错；（2）清理临时文件；（3）当前二进制不变；（4）绝不产生 .old 备份。
func TestUpdater_DownloadAndReplace_WrongChecksumNoBackup(t *testing.T) {
	binary := []byte("real-binary-content-v3")
	mux := http.NewServeMux()
	mux.HandleFunc("/bin", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(binary)
	})
	mux.HandleFunc("/sums", func(w http.ResponseWriter, _ *http.Request) {
		// 故意写入错误哈希（全 0），与真实内容不符。
		_, _ = w.Write([]byte("0000000000000000000000000000000000000000000000000000000000000000  cfopt\n"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	u := newTestUpdater(srv)
	dir := t.TempDir()
	current := filepath.Join(dir, "cfopt")
	require.NoError(t, os.WriteFile(current, []byte("old-binary-v1"), 0o755))

	info := &ReleaseInfo{
		Version: "1.0.0",
		Assets: []Asset{
			{Name: "cfopt", URL: srv.URL + "/bin", Size: int64(len(binary))},
			{Name: "SHA256SUMS", URL: srv.URL + "/sums"},
		},
	}
	err := u.DownloadAndReplace(context.Background(), current, info, Options{Asset: "cfopt"})
	require.Error(t, err, "SHA256 校验失败必须报错")
	assert.Contains(t, err.Error(), "SHA256", "错误应明确指出 SHA256 校验失败")

	// 当前二进制不变。
	data, _ := os.ReadFile(current)
	assert.Equal(t, "old-binary-v1", string(data), "SHA256 失败时当前二进制不应被改动")

	// 临时文件已清理。
	_, statErr := os.Stat(filepath.Join(dir, "cfopt.download"))
	assert.True(t, os.IsNotExist(statErr), "失败后应清理临时下载文件")

	// 绝不产生 .old 备份（证明原子 rename 未发生，无半替换状态）。
	_, oldStatErr := os.Stat(current + ".old")
	assert.True(t, os.IsNotExist(oldStatErr), "SHA256 失败时不应产生 .old 备份（无半替换）")
}
