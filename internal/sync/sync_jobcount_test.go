package sync

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// mockTester 返回固定 IP 的假测速器，避免依赖外部 cfst 二进制。
type mockTester struct{ ip string }

func (t *mockTester) Run(ctx context.Context, outputDir string, progress speedtest.ProgressFunc) ([]speedtest.SpeedResult, error) {
	return []speedtest.SpeedResult{{IP: t.ip, Latency: 10, Speed: 100, Colo: "HKG"}}, nil
}
func (t *mockTester) ParseOutput(path string) ([]speedtest.SpeedResult, error) { return nil, nil }
func (t *mockTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{IP: r.IP, Latency: r.Latency, Speed: r.Speed, Colo: r.Colo})
	}
	return recs
}

// newTestSyncer 用假测速器 + 内置模块注册表构造 Syncer（不依赖 cfst 二进制）。
func newTestSyncer(hist history.HistoryStore) *Syncer {
	reg := dns.NewRegistry()
	reg.RegisterAll(dns.BuiltinModules)
	reg.Register(dns.NewCFModule(hist))
	return NewSyncer(&mockTester{ip: "1.2.3.4"}, reg, hist)
}

// TestSpeedtestJobCount_ISPLines 锁死 Task#12 的超时估算依据：
// isp_lines 多线路域名应只计入「逐线路测速任务数」（= ISP 线路数），
// 而不能按线程数除小（旧公式会把 4 个串行测速任务误估成极短时间 → 结构性超时）。
func TestSpeedtestJobCount_ISPLines(t *testing.T) {
	syncer := newTestSyncer(history.NewJSONLStore(t.TempDir()))
	cfg := &config.Config{
		DNSPod: &config.DNSPodConfig{
			Enabled:         true,
			Mode:            "isp_lines",
			SpeedTestPerISP: true,
			Domain:          "www.example.com",
			ISP: map[string]config.ISPConf{
				"电信": {}, "联通": {}, "移动": {}, "默认": {},
			},
		},
	}

	// 单线路域名级测速应跳过；逐线路 = 4 条线路 → 4 个串行 cfst 任务。
	assert.Equal(t, 4, syncer.SpeedtestJobCount(cfg), "isp_lines 域名应只计逐线路任务数")
}

// TestSpeedtestJobCount_SingleLineAddsPerDomain 单线路 DNSPod 域名（配置了 SpeedTestColo）应计 1 个域名级测速任务。
func TestSpeedtestJobCount_SingleLineAddsPerDomain(t *testing.T) {
	syncer := newTestSyncer(history.NewJSONLStore(t.TempDir()))
	cfg := &config.Config{
		DNSPod: &config.DNSPodConfig{
			Enabled:       true,
			Mode:          "single",
			Domain:        "www.example.com",
			IPFilePath:    "assets/data/dnspod-dns/www.example.com.iplist",
			SpeedTestColo: "HKG",
			TakeIPNum:     5,
		},
	}

	// 单线路：1 个域名级测速任务；无逐线路任务。
	assert.Equal(t, 1, syncer.SpeedtestJobCount(cfg))
}
