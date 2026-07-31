package ipsource

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestCSVParser_Read 验证 cfst 7 列 csv 解析：
// IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码，首行列头(首字段为 ip)被跳过。
func TestCSVParser_Read(t *testing.T) {
	content := `IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码
1.1.1.1,100,100,0,15.2,55.5,HKG
2.2.2.2,100,99,1,20,40,NRT
notanip,1,1,0,5,5,XYZ
`
	p := writeSample(t, "result.csv", content)

	recs, err := (&CSVParser{}).Read(p)
	require.NoError(t, err)
	require.Len(t, recs, 2, "表头与非法 IP 行应被跳过，剩 2 条")

	assert.Equal(t, "1.1.1.1", recs[0].IP)
	assert.Equal(t, 15.2, recs[0].Latency) // 平均延迟 = 第 5 列
	assert.Equal(t, 55.5, recs[0].Speed)   // 下载速度 = 第 6 列
	assert.Equal(t, "HKG", recs[0].Colo)   // 地区码 = 第 7 列

	assert.Equal(t, "2.2.2.2", recs[1].IP)
	assert.Equal(t, "NRT", recs[1].Colo)
}

// TestCSVParser_ReadNoHeader 验证无表头的纯数据 csv（首行首字段为真实 IP）也能正确解析。
func TestCSVParser_ReadNoHeader(t *testing.T) {
	content := `3.3.3.3,100,100,0,12,33,SHA
4.4.4.4,100,100,0,9,77,BJS
`
	p := writeSample(t, "nohdr.csv", content)

	recs, err := (&CSVParser{}).Read(p)
	require.NoError(t, err)
	require.Len(t, recs, 2)
	assert.Equal(t, "3.3.3.3", recs[0].IP)
	assert.Equal(t, "SHA", recs[0].Colo)
}

// TestCSVParser_ReadShortRow 验证列数不足 7 的行被跳过。
func TestCSVParser_ReadShortRow(t *testing.T) {
	content := `IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码
1.1.1.1,100,100,0,15.2,55.5,HKG
short,row
`
	p := writeSample(t, "short.csv", content)
	recs, err := (&CSVParser{}).Read(p)
	require.NoError(t, err)
	assert.Len(t, recs, 1)
}
