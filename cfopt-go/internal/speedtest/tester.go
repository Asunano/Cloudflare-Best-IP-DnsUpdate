package speedtest

import (
	"context"

	"cfopt/internal/config"
	"cfopt/internal/ipsource"
)

// ProgressFunc 测速进度回调：stage 为阶段名（当前恒为 "speedtest"），
// cur/total 为 cfst 解析出的 "X / Y" 当前/总数。为 nil 时调用方不关心进度。
type ProgressFunc func(stage string, cur, total int)

// SpeedTester 测速封装接口。
type SpeedTester interface {
	// Run 执行测速并返回结果。progress 为可选进度回调（可为 nil）。
	Run(ctx context.Context, cfg *config.CFIPConfig, progress ProgressFunc) ([]SpeedResult, error)
	// ParseOutput 解析 cfst 生成的输出文件（通常为 .csv）。
	ParseOutput(path string) ([]SpeedResult, error)
	// ToIPList 将测速结果转换为 IPRecord 列表（供 DNS 同步使用）。
	ToIPList(results []SpeedResult) []ipsource.IPRecord
}
