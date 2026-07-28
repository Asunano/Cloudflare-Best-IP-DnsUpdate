package sync

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/ipsource"
)

// TestWriteIPList_ForcesIplistEdgeCases 加固需求 #1：WriteIPList 写入前若扩展名非 .iplist，
// 必须强制改写为 .iplist（保留目录与基名、只改扩展名）。覆盖更多边界：
//   - .txt → .iplist
//   - 无扩展名 → .iplist
//   - .csv → .iplist
//   - 嵌套目录 a/b/c.txt → a/b/c.iplist
//   - 已是 .iplist → 保持原样（不改写、不重复加扩展名）
//
// 并验证落盘内容格式 IP|延迟|速度|地区码，且能被 IPListParser 回读（round-trip）。
func TestWriteIPList_ForcesIplistEdgeCases(t *testing.T) {
	dir := t.TempDir()
	recs := []ipsource.IPRecord{{IP: "1.2.3.4", Latency: 10, Speed: 100, Colo: "HKG"}}

	cases := []struct {
		name     string
		inPath   string // 传给 WriteIPList 的路径
		wantBase string // 期望落盘的基名（不含扩展名）
	}{
		{"txt", filepath.Join(dir, "best.txt"), "best"},
		{"noext", filepath.Join(dir, "best"), "best"},
		{"csv", filepath.Join(dir, "best.csv"), "best"},
		{"nested", filepath.Join(dir, "a", "b", "c.txt"), "c"},
		{"already", filepath.Join(dir, "ok.iplist"), "ok"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			require.NoError(t, WriteIPList(recs, c.inPath))

			wantPath := filepath.Join(filepath.Dir(c.inPath), c.wantBase+".iplist")
			content, err := os.ReadFile(wantPath)
			require.NoError(t, err, "应落盘为 .iplist：%s", wantPath)
			assert.Contains(t, string(content), "1.2.3.4")
			// 表头为「# IP地址|延迟(ms)|下载速度(MB/s)|地区码」，且含 IP|延迟 段。
			assert.Contains(t, string(content), "IP地址|延迟(ms)|下载速度(MB/s)|地区码", "应包含表头")

			// 原（错误）扩展名不应被写出（txt/csv 分支）。
			if filepath.Ext(c.inPath) != ".iplist" {
				_, statErr := os.Stat(c.inPath)
				assert.True(t, os.IsNotExist(statErr), "不应写出原始扩展名文件: %s", c.inPath)
			}

			// round-trip：能被 IPListParser 正确回读。
			got, err := (&ipsource.IPListParser{}).Read(wantPath)
			require.NoError(t, err)
			require.Len(t, got, 1)
			assert.Equal(t, "1.2.3.4", got[0].IP)
			assert.Equal(t, "HKG", got[0].Colo)
		})
	}
}

// TestWriteIPList_NoDoubleExtension 验证：输入已是 .iplist 时不会变成 .iplist.iplist。
func TestWriteIPList_NoDoubleExtension(t *testing.T) {
	dir := t.TempDir()
	recs := []ipsource.IPRecord{{IP: "5.6.7.8", Latency: 1, Speed: 1, Colo: "LAX"}}
	p := filepath.Join(dir, "already.iplist")
	require.NoError(t, WriteIPList(recs, p))

	// 不应存在 already.iplist.iplist
	_, statErr := os.Stat(filepath.Join(dir, "already.iplist.iplist"))
	assert.True(t, os.IsNotExist(statErr), "已是 .iplist 不应重复加扩展名")
}
