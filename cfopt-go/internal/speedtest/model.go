// Package speedtest 封装 cfst 外部测速二进制（不实现原生测速）。
package speedtest

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
