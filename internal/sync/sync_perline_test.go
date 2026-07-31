package sync

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// fakePerLineModule 实现 SyncModule + PerLineSpeedtester + PerLineSyncer：启用逐线路测速，
// 声明 4 条线路，SyncLine/SyncUnified 仅计数（不写磁盘），用于验证编排层「测完即同步」行为。
type fakePerLineModule struct {
	id              string
	ipFile          string
	synced          int
	syncLineCount   int
	syncUnifiedCount int
}

func (m *fakePerLineModule) ID() string { return m.id }
func (m *fakePerLineModule) Enabled(cfg *config.Config) bool             { return true }
func (m *fakePerLineModule) IPSourceFiles(cfg *config.Config) []string   { return []string{m.ipFile} }
func (m *fakePerLineModule) Sync(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	// 模拟真实 dnspodModule 的行为：isp_lines + 逐线路测速配置下，
	// 完整 Sync 提前返回（各线路已由 SyncLine 即时同步、统一子域已由 SyncUnified 收尾），
	// 不再重复逐线路同步。用 synced 计数可验证 step③ 未对 per-line 模块重复执行完整 Sync。
	if cfg != nil && cfg.DNSPod != nil && cfg.DNSPod.Mode == "isp_lines" && cfg.DNSPod.SpeedTestPerISP {
		return &dns.SyncResult{}, nil
	}
	m.synced++
	return &dns.SyncResult{}, nil
}
func (m *fakePerLineModule) UsePerLineSpeedtest(cfg *config.Config) bool { return true }
func (m *fakePerLineModule) SpeedtestJobs(cfg *config.Config) []dns.LineSpeedtestJob {
	return []dns.LineSpeedtestJob{
		{Line: "电信", SubDomain: "www", Domain: "example.com"},
		{Line: "联通", SubDomain: "www", Domain: "example.com"},
		{Line: "移动", SubDomain: "www", Domain: "example.com"},
		{Line: "默认", SubDomain: "www", Domain: "example.com"},
	}
}
func (m *fakePerLineModule) SyncLine(ctx context.Context, cfg *config.Config, job dns.LineSpeedtestJob) (*dns.SyncResult, error) {
	m.syncLineCount++
	return &dns.SyncResult{}, nil
}
func (m *fakePerLineModule) SyncUnified(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	m.syncUnifiedCount++
	return &dns.SyncResult{}, nil
}

// taggedTester 返回固定 IP 的假测速器，便于区分「全局 best」与「per-line 结果」。
type taggedTester struct{ ip string }

func (t *taggedTester) Run(ctx context.Context, outputDir string, progress speedtest.ProgressFunc) ([]speedtest.SpeedResult, error) {
	return []speedtest.SpeedResult{{IP: t.ip, Latency: 10, Speed: 100, Colo: "HKG"}}, nil
}
func (t *taggedTester) ParseOutput(path string) ([]speedtest.SpeedResult, error) { return nil, nil }
func (t *taggedTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{IP: r.IP, Latency: r.Latency, Speed: r.Speed, Colo: r.Colo})
	}
	return recs
}

// TestSyncAll_PerLineSkipsGlobalWrite 验证 P0-2 回归守护：
// 当模块启用逐线路测速（PerLineSpeedtester 且 UsePerLineSpeedtest 为真）时，
// 该模块只接受各自 per-line 测速结果写入，绝不接受全局 best（否则覆盖各自文件、复活 P0-2）。

// TestWriteIPList_ForcesIplist 验证 WriteIPList 写入前若扩展名非 .iplist 则强制改写（防 .txt 误解析）。
func TestWriteIPList_ForcesIplist(t *testing.T) {
	dir := t.TempDir()
	// 给一个 .txt 路径，应被改写为 .iplist 落盘。
	recs := []ipsource.IPRecord{{IP: "1.2.3.4", Latency: 10, Speed: 100, Colo: "HKG"}}
	require.NoError(t, WriteIPList(recs, filepath.Join(dir, "best.txt")))

	content, err := os.ReadFile(filepath.Join(dir, "best.iplist"))
	require.NoError(t, err, "应落盘为 .iplist 而非 .txt")
	assert.Contains(t, string(content), "1.2.3.4")

	// 原 .txt 不应存在。
	_, statErr := os.Stat(filepath.Join(dir, "best.txt"))
	assert.True(t, os.IsNotExist(statErr), "不应写出 .txt 文件")
}

// TestSyncAll_PerLineSyncImmediately 验证逐线路「测完即同步」编排（用户需求：测完哪个线路就直接同步，以免并发过高）：
//   - step② 中每条线路测速完成、写入各自 iplist 后，立即调用一次 SyncLine（而非等全部线路测完再统一 Sync）；
//   - 所有线路测速完成后，调用一次 SyncUnified 写统一子域记录收尾；
//   - step③ 对 isp_lines + 逐线路测速配置的 per-line 模块不再重复执行完整 Sync（真实 dnspodModule.Sync 提前返回）。
func TestSyncAll_PerLineSyncImmediately(t *testing.T) {
	hist := history.NewJSONLStore(t.TempDir())
	reg := dns.NewRegistry()
	mod := &fakePerLineModule{id: "fakepl"}
	reg.Register(mod)
	syncer := NewSyncer(&mockTester{ip: "1.2.3.4"}, reg, hist)
	// 注入假 per-line 测速器，避免依赖外部 cfst 二进制（SyncAll step② 通过 perLineTesterFactory 取测速器）。
	syncer.perLineTesterFactory = func(colo string, httping bool, threads int) (speedtest.SpeedTester, error) {
		return &mockTester{ip: "1.2.3.4"}, nil
	}

	cfg := &config.Config{
		DNSPod: &config.DNSPodConfig{
			Enabled:         true,
			Mode:            "isp_lines",
			SpeedTestPerISP: true,
			Domain:          "www.example.com",
		},
	}

	summary, err := syncer.SyncAll(context.Background(), cfg, nil)
	require.NoError(t, err)
	require.NotNil(t, summary)

	assert.Equal(t, 4, mod.syncLineCount, "每条线路测速完成应立即调用一次 SyncLine（共 4 条线路）")
	assert.Equal(t, 1, mod.syncUnifiedCount, "所有线路完成后应调用一次 SyncUnified 收尾")
	assert.Equal(t, 0, mod.synced, "isp_lines 配置的 per-line 模块在 step③ 不应再重复执行完整 Sync")
}
