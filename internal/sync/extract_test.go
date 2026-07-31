package sync

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/speedtest"
)

// TestExtractBestIPs_SortOrder 验证排序规则：先速度降序，再延迟升序。
func TestExtractBestIPs_SortOrder(t *testing.T) {
	results := []speedtest.SpeedResult{
		{IP: "1.1.1.1", Speed: 100, Latency: 10},
		{IP: "2.2.2.2", Speed: 100, Latency: 5}, // 同速，延迟更小，应排在 1.1.1.1 前
		{IP: "3.3.3.3", Speed: 50, Latency: 1},
		{IP: "4.4.4.4", Speed: 200, Latency: 50}, // 速度最大，排第一
	}

	got := ExtractBestIPs(results, 0)
	require.Len(t, got, 4)

	want := []string{"4.4.4.4", "2.2.2.2", "1.1.1.1", "3.3.3.3"}
	for i, ip := range want {
		assert.Equal(t, ip, got[i].IP, "第 %d 位应为 %s", i, ip)
	}
	// 验证类型映射正确
	assert.Equal(t, 10.0, got[2].Latency)
}

// TestExtractBestIPs_LimitN 验证 n 限制生效。
func TestExtractBestIPs_LimitN(t *testing.T) {
	results := []speedtest.SpeedResult{
		{IP: "1.1.1.1", Speed: 100, Latency: 10},
		{IP: "2.2.2.2", Speed: 100, Latency: 5},
		{IP: "3.3.3.3", Speed: 50, Latency: 1},
		{IP: "4.4.4.4", Speed: 200, Latency: 50},
	}

	// n=2 -> 取前 2（速度最高者）
	got := ExtractBestIPs(results, 2)
	require.Len(t, got, 2)
	assert.Equal(t, "4.4.4.4", got[0].IP)
	assert.Equal(t, "2.2.2.2", got[1].IP)
}

// TestExtractBestIPs_NonPositive 验证 n<=0 返回全部（仍按序）。
func TestExtractBestIPs_NonPositive(t *testing.T) {
	results := []speedtest.SpeedResult{
		{IP: "1.1.1.1", Speed: 10, Latency: 1},
		{IP: "2.2.2.2", Speed: 20, Latency: 2},
	}
	assert.Len(t, ExtractBestIPs(results, 0), 2)
	assert.Len(t, ExtractBestIPs(results, -3), 2)
}

// TestExtractBestIPs_NExceedsLen 验证 n 大于结果数时返回全部。
func TestExtractBestIPs_NExceedsLen(t *testing.T) {
	results := []speedtest.SpeedResult{
		{IP: "1.1.1.1", Speed: 10, Latency: 1},
	}
	assert.Len(t, ExtractBestIPs(results, 100), 1)
}

// TestExtractBestIPs_Empty 验证空输入返回空切片。
func TestExtractBestIPs_Empty(t *testing.T) {
	assert.Empty(t, ExtractBestIPs(nil, 5))
	assert.Empty(t, ExtractBestIPs([]speedtest.SpeedResult{}, 0))
}
