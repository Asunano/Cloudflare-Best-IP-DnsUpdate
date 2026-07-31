package dns

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestReadTargetIPs_MissingFileSkipped 锁定「IP 源文件不存在时跳过该文件（非阻断）」的回退（历史 bug 回归锁）：
//
// 曾用 os.IsNotExist 判断，但 ipsource.Read 返回的是 CFOptError 多层包装的错误，
// os.IsNotExist 不走 Unwrap 链而永远为 false —— 回退成为死代码，首次部署尚未生成
// per-line iplist 时整个 dnspod 模块报 `成功=false ... ipsource:iplist:open: no such file or directory`。
// 修复后必须用 errors.Is(err, fs.ErrNotExist) 命中包装链。
func TestReadTargetIPs_MissingFileSkipped(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "not-exist-电信.iplist")

	// 全部文件缺失：应视作“尚未生成”，返回 (nil, nil) 而非错误。
	ips, err := readTargetIPs([]string{missing}, 0)
	require.NoError(t, err, "缺失的 IP 源文件必须被跳过而非报错")
	assert.Nil(t, ips)

	// 缺失 + 存在混合：缺失文件跳过，存在文件正常读取。
	existing := filepath.Join(dir, "ok.iplist")
	require.NoError(t, os.WriteFile(existing, []byte("1.1.1.1|10|5.0|HKG\n"), 0o600))

	ips, err = readTargetIPs([]string{missing, existing}, 0)
	require.NoError(t, err)
	assert.Equal(t, []string{"1.1.1.1"}, ips)
}
