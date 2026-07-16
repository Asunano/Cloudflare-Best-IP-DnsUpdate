// Package speedtest 封装 cfst 外部测速二进制（不实现原生测速）。
package speedtest

import "cfopt/internal/ipsource"

// SpeedResult cfst 测速输出的一条结果。
type SpeedResult struct {
	IP       string  `json:"ip"`
	Sent     int     `json:"sent"`
	Received int     `json:"received"`
	Loss     float64 `json:"loss"`
	Latency  float64 `json:"latency"`
	Speed    float64 `json:"speed"`
	Colo     string  `json:"colo"`
}

// ToIPList 将测速结果转换为 IPRecord 列表（与 CFSTTester.ToIPList 行为一致）。
// 供 IPC speedtest.run 在返回结果的同时补写 .iplist，与 CLI `cfopt speedtest --output` 默认行为对齐。
func ToIPList(results []SpeedResult) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{
			IP:      r.IP,
			Latency: r.Latency,
			Speed:   r.Speed,
			Colo:    r.Colo,
		})
	}
	return recs
}
