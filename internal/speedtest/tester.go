package speedtest

import (
	"context"

	"cfopt/internal/ipsource"
)

// ProgressFunc 测速进度回调。
type ProgressFunc func(stage string, cur, total int)

// SpeedTester 测速封装接口。
type SpeedTester interface {
	// Run 执行一次 cfst 测速。传给 cfst 的参数仅 -o result.csv -f ip.txt，
	// 其余全部走 cfst 内置默认值。
	Run(ctx context.Context, outputDir string, progress ProgressFunc) ([]SpeedResult, error)
	ParseOutput(path string) ([]SpeedResult, error)
	ToIPList(results []SpeedResult) []ipsource.IPRecord
}
