package speedtest

import (
	"context"

	"cfopt/internal/config"
	"cfopt/internal/ipsource"
)

// SpeedTester 测速封装接口。
type SpeedTester interface {
	// Run 执行测速并返回结果。
	Run(ctx context.Context, cfg *config.CFIPConfig) ([]SpeedResult, error)
	// ParseOutput 解析 cfst 生成的输出文件（通常为 .csv）。
	ParseOutput(path string) ([]SpeedResult, error)
	// ToIPList 将测速结果转换为 IPRecord 列表（供 DNS 同步使用）。
	ToIPList(results []SpeedResult) []ipsource.IPRecord
}
