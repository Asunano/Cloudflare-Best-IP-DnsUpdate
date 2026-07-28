package sync

import (
	"context"
	"errors"
	"testing"

	"cfopt/internal/config"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// failTester 记录调用次数、按序返回预设错误，用于验证自动重测逻辑。
// 需实现 SpeedTester 接口的全部方法（Run/ParseOutput/ToIPList）。
type failTester struct {
	calls   int
	failN   int // 前 failN 次返回 err
	err     error
	results []speedtest.SpeedResult
}

func (f *failTester) Run(ctx context.Context, cfg *config.CFIPConfig) ([]speedtest.SpeedResult, error) {
	f.calls++
	if f.calls <= f.failN {
		return nil, f.err
	}
	return f.results, nil
}

// ParseOutput / ToIPList 仅用于满足 SpeedTester 接口（本测试不触发解析逻辑）。
func (f *failTester) ParseOutput(path string) ([]speedtest.SpeedResult, error) {
	return nil, nil
}

func (f *failTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	return nil
}

func makeCfg(maxRetry int) *config.Config {
	return &config.Config{CFIP: &config.CFIPConfig{SpeedTest: config.SpeedTestConfig{MaxRetry: maxRetry}}}
}

func TestRunSpeedtest_HonorsMaxRetry(t *testing.T) {
	someErr := errors.New("boom")

	// 1) max_retry=1：首次失败即终止，仅调用 1 次。
	ft1 := &failTester{failN: 10, err: someErr}
	s1 := &Syncer{tester: ft1}
	if _, err := s1.runSpeedtest(context.Background(), makeCfg(1)); err == nil {
		t.Fatal("期望错误")
	}
	if ft1.calls != 1 {
		t.Fatalf("max_retry=1 应只调用 1 次，实际 %d", ft1.calls)
	}

	// 2) max_retry=3：前 2 次失败、第 3 次成功，应调用 3 次并返回结果。
	ft2 := &failTester{failN: 2, err: someErr, results: []speedtest.SpeedResult{{IP: "1.2.3.4"}}}
	s2 := &Syncer{tester: ft2}
	res, err := s2.runSpeedtest(context.Background(), makeCfg(3))
	if err != nil {
		t.Fatalf("期望成功，实际 err=%v", err)
	}
	if ft2.calls != 3 {
		t.Fatalf("max_retry=3 应调用 3 次，实际 %d", ft2.calls)
	}
	if len(res) != 1 || res[0].IP != "1.2.3.4" {
		t.Fatalf("返回结果错误: %+v", res)
	}

	// 3) 未配置 max_retry（0）：首次成功，调用 1 次。
	ft3 := &failTester{results: []speedtest.SpeedResult{{IP: "9.9.9.9"}}}
	s3 := &Syncer{tester: ft3}
	if _, err := s3.runSpeedtest(context.Background(), makeCfg(0)); err != nil {
		t.Fatalf("期望成功: %v", err)
	}
	if ft3.calls != 1 {
		t.Fatalf("默认应调用 1 次，实际 %d", ft3.calls)
	}

	// 4) 首次成功即返回，不浪费重测。
	ft4 := &failTester{results: []speedtest.SpeedResult{{IP: "8.8.8.8"}}}
	s4 := &Syncer{tester: ft4}
	if _, err := s4.runSpeedtest(context.Background(), makeCfg(5)); err != nil {
		t.Fatalf("期望成功: %v", err)
	}
	if ft4.calls != 1 {
		t.Fatalf("首次成功应只调用 1 次，实际 %d", ft4.calls)
	}
}
