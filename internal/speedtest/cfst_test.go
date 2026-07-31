package speedtest

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseOutput_Success(t *testing.T) {
	dir := t.TempDir()
	csv := filepath.Join(dir, "result.csv")
	content := "IP地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n1.1.1.1,4,4,0,10.5,50.0,HKG\n"
	require.NoError(t, os.WriteFile(csv, []byte(content), 0o644))
	tester := &CFSTTester{}
	results, err := tester.ParseOutput(csv)
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "1.1.1.1", results[0].IP)
	assert.InDelta(t, 10.5, results[0].Latency, 0.01)
	assert.InDelta(t, 50.0, results[0].Speed, 0.01)
	assert.Equal(t, "HKG", results[0].Colo)
}

func TestParseOutput_Empty(t *testing.T) {
	dir := t.TempDir()
	csv := filepath.Join(dir, "empty.csv")
	require.NoError(t, os.WriteFile(csv, []byte("IP地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n"), 0o644))
	tester := &CFSTTester{}
	results, err := tester.ParseOutput(csv)
	require.NoError(t, err)
	assert.Empty(t, results)
}

func TestToIPList(t *testing.T) {
	results := []SpeedResult{
		{IP: "1.1.1.1", Latency: 10.5, Speed: 50.0, Colo: "HKG"},
	}
	tester := &CFSTTester{}
	records := tester.ToIPList(results)
	require.Len(t, records, 1)
	assert.Equal(t, "1.1.1.1", records[0].IP)
}

func TestParseFloat(t *testing.T) {
	assert.InDelta(t, 10.5, parseFloat("10.5"), 0.01)
	assert.InDelta(t, 0, parseFloat(""), 0.01)
	assert.InDelta(t, 0, parseFloat("abc"), 0.01)
	assert.InDelta(t, 123.456, parseFloat("123.456\r"), 0.01)
}
