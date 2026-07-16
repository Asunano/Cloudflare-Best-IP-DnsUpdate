package ipsource

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// writeSample 将内容写入临时目录中的指定文件名，返回完整路径。
func writeSample(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, name)
	require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	return p
}

// TestIPListParser_Read 验证 .iplist 格式 IP|延迟|速度|地区码 解析，
// 跳过注释/空行/字段不足/非法 IP 行，并正确填充 IPRecord 各字段。
func TestIPListParser_Read(t *testing.T) {
	content := `# 优选 IP 列表
1.1.1.1|10.5|50.2|HKG
2.2.2.2|20|30|NRT
8.8.8.8|5|99|LAX

# 下面这些应被跳过：
bad line
notanip|1|2|XYZ
0.0.0.0|1|2|XXX
255.255.255.255|1|2|YYY
`
	p := writeSample(t, "list.iplist", content)

	recs, err := (&IPListParser{}).Read(p)
	require.NoError(t, err)
	require.Len(t, recs, 3, "应解析出 3 条合法记录")

	assert.Equal(t, "1.1.1.1", recs[0].IP)
	assert.Equal(t, 10.5, recs[0].Latency)
	assert.Equal(t, 50.2, recs[0].Speed)
	assert.Equal(t, "HKG", recs[0].Colo)

	assert.Equal(t, "2.2.2.2", recs[1].IP)
	assert.Equal(t, "NRT", recs[1].Colo)

	assert.Equal(t, "8.8.8.8", recs[2].IP)
	assert.Equal(t, "LAX", recs[2].Colo)
}

// TestIPListParser_ReadMissingFile 验证文件不存在返回 error。
func TestIPListParser_ReadMissingFile(t *testing.T) {
	_, err := (&IPListParser{}).Read(filepath.Join(t.TempDir(), "nope.iplist"))
	require.Error(t, err)
}

// TestIPListParser_ReadEmpty 验证空文件返回空切片。
func TestIPListParser_ReadEmpty(t *testing.T) {
	p := writeSample(t, "empty.iplist", "# only comment\n\n")
	recs, err := (&IPListParser{}).Read(p)
	require.NoError(t, err)
	assert.Empty(t, recs)
}
