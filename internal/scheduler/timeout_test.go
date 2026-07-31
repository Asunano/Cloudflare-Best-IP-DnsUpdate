package scheduler

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
	"cfopt/internal/sync"
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

// newTestScheduler 用假测速器 + 内置模块注册表构造 Scheduler（不依赖 cfst 二进制）。
func newTestScheduler(cfg *config.Config, hist history.HistoryStore) *Scheduler {
	reg := dns.NewRegistry()
	reg.RegisterAll(dns.BuiltinModules)
	reg.Register(dns.NewCFModule(hist))
	syncer := sync.NewSyncer(&mockTester{ip: "1.2.3.4"}, reg, hist)
	return &Scheduler{syncer: syncer}
}

// TestComputeTimeout_ConfigOverride 配置 watchdog_timeout 优先于自动估算。
func TestComputeTimeout_ConfigOverride(t *testing.T) {
	cfg := &config.Config{
		Global: &config.GlobalConfig{
			Schedule: config.ScheduleConfig{WatchdogTimeout: "40m"},
		},
	}
	sched := newTestScheduler(cfg, history.NewJSONLStore(t.TempDir()))
	assert.Equal(t, 40*time.Minute, sched.computeTimeout(cfg))
}

// TestComputeTimeout_ISPLinesJobBased 4 线路 isp_lines 域名：超时按 4 个串行任务估算（约 42m），
// 远大于旧公式的 10m 下限，避免结构性超时。
func TestComputeTimeout_ISPLinesJobBased(t *testing.T) {
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
	sched := newTestScheduler(cfg, history.NewJSONLStore(t.TempDir()))
	// 2m 缓冲 + 4×15m = 62m。
	assert.Equal(t, 62*time.Minute, sched.computeTimeout(cfg))
}

// TestComputeTimeout_Floor 无 syncer（jobs=1）时取 缓冲+单任务 = 17m，且不低于下限 10m。
func TestComputeTimeout_Floor(t *testing.T) {
	cfg := &config.Config{}
	sched := &Scheduler{}
	assert.Equal(t, 17*time.Minute, sched.computeTimeout(cfg))
}
