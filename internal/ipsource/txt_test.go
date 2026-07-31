package ipsource

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestTXTParser_Read 验证纯 IP 文本解析：每行一个 IP，支持 # 注释与空白行，
// 兼容 "IP ..." / "IP,..." 形式，并经 ValidateIP 过滤非法行。
func TestTXTParser_Read(t *testing.T) {
	content := `# Cloudflare 优选 IP
1.1.1.1
2.2.2.2 extra
3.3.3.3,

0.0.0.0
notanip
255.255.255.255
`
	p := writeSample(t, "list.txt", content)

	recs, err := (&TXTParser{}).Read(p)
	require.NoError(t, err)

	// 合法: 1.1.1.1 / 2.2.2.2(取首个 token) / 3.3.3.3(去除尾部逗号)
	// 跳过: 0.0.0.0 / notanip / 255.255.255.255 / 空白行 / 注释
	require.Len(t, recs, 3)
	assert.Equal(t, "1.1.1.1", recs[0].IP)
	assert.Equal(t, "2.2.2.2", recs[1].IP)
	assert.Equal(t, "3.3.3.3", recs[2].IP)
}

// TestTXTParser_ReadAllInvalid 验证全为非法/空内容时返回空切片且无误。
func TestTXTParser_ReadAllInvalid(t *testing.T) {
	content := `# 注释
   
notanip
0.0.0.0
`
	p := writeSample(t, "bad.txt", content)
	recs, err := (&TXTParser{}).Read(p)
	require.NoError(t, err)
	assert.Empty(t, recs)
}
