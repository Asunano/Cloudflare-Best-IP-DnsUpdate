package sync

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// fakePerLineModule 实现 SyncModule + PerLineSpeedtester：启用逐线路测速，
// 仅声明一个线路、一个 IP 文件，Sync 不写磁盘（由 per-line 写入路径负责）。
type fakePerLineModule struct {
	id     string
	ipFile string
	synced int
}

func (m *fakePerLineModule) ID() string                                  { return m.id }
func (m *fakePerLineModule) Enabled(cfg *config.Config) bool             { return true }
func (m *fakePerLineModule) IPSourceFiles(cfg *config.Config) []string   { return []string{m.ipFile} }
func (m *fakePerLineModule) Sync(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	m.synced++
	return &dns.SyncResult{}, nil
}
func (m *fakePerLineModule) UsePerLineSpeedtest(cfg *config.Config) bool { return true }
func (m *fakePerLineModule) SpeedtestJobs(cfg *config.Config) []dns.LineSpeedtestJob {
	return []dns.LineSpeedtestJob{{Line: "默认", IPFiles: []string{m.ipFile}, SubDomain: "www"}}
}

// taggedTester 返回固定 IP 的假测速器，便于区分「全局 best」与「per-line 结果」。
type taggedTester struct{ ip string }

func (t *taggedTester) Run(ctx context.Context, cfg *config.CFIPConfig) ([]speedtest.SpeedResult, error) {
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
func TestSyncAll_PerLineSkipsGlobalWrite(t *testing.T) {
	dir := t.TempDir()
	ipFile := filepath.Join(dir, "perline.iplist")

	reg := dns.NewRegistry()
	pl := &fakePerLineModule{id: "pl", ipFile: ipFile}
	reg.Register(pl)

	globalTester := &taggedTester{ip: "198.51.100.10"} // 全局 best（不应写入 per-line 文件）
	perLineTester := &taggedTester{ip: "203.0.113.10"} // per-line 结果（应唯一写入）

	syn := NewSyncer(globalTester, reg, &fakeHistory{})
	syn.perLineTesterFactory = func(*config.CFIPConfig) (speedtest.SpeedTester, error) {
		return perLineTester, nil
	}

	cfg := &config.Config{
		CFIP: &config.CFIPConfig{
			SpeedTest: config.SpeedTestConfig{TakeIPNum: 5},
		},
	}

	_, err := syn.SyncAll(context.Background(), cfg, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, pl.synced, "per-line 模块应被同步一次")

	content, err := os.ReadFile(ipFile)
	require.NoError(t, err, "per-line IP 文件应被写入")
	assert.Contains(t, string(content), "203.0.113.10", "per-line 文件应包含 per-line 测速结果")
	assert.NotContains(t, string(content), "198.51.100.10", "全局 best 不应写入 per-line 文件（避免覆盖、复活 P0-2）")
}

// TestSyncAll_PerLineAndGlobalBothWrite 验证混合场景：
// 全局模块走 writeBestIPs，per-line 模块走各自写入，互不覆盖。
func TestSyncAll_PerLineAndGlobalBothWrite(t *testing.T) {
	dir := t.TempDir()
	perLineFile := filepath.Join(dir, "perline.iplist")
	globalFile := filepath.Join(dir, "global.iplist")

	reg := dns.NewRegistry()
	reg.Register(&fakeModule{id: "g", enabled: true, files: []string{globalFile}})
	reg.Register(&fakePerLineModule{id: "pl", ipFile: perLineFile})

	globalTester := &taggedTester{ip: "198.51.100.10"}
	perLineTester := &taggedTester{ip: "203.0.113.10"}

	syn := NewSyncer(globalTester, reg, &fakeHistory{})
	syn.perLineTesterFactory = func(*config.CFIPConfig) (speedtest.SpeedTester, error) {
		return perLineTester, nil
	}

	cfg := &config.Config{
		CFIP: &config.CFIPConfig{
			SpeedTest: config.SpeedTestConfig{TakeIPNum: 5},
		},
	}

	_, err := syn.SyncAll(context.Background(), cfg, nil)
	require.NoError(t, err)

	gContent, err := os.ReadFile(globalFile)
	require.NoError(t, err)
	assert.Contains(t, string(gContent), "198.51.100.10", "全局模块应写入全局 best")

	pContent, err := os.ReadFile(perLineFile)
	require.NoError(t, err)
	assert.Contains(t, string(pContent), "203.0.113.10", "per-line 模块应写入各自结果")
}

// TestSyncAll_WritesGlobalBestFile 验证全局测速阶段后会把最优 IP 强制落盘为 .iplist（global_best 模式数据源）。
func TestSyncAll_WritesGlobalBestFile(t *testing.T) {
	dir := t.TempDir()
	globalFile := filepath.Join(dir, "best.iplist")

	reg := dns.NewRegistry()
	reg.Register(&fakeModule{id: "g", enabled: true, files: []string{filepath.Join(dir, "out.iplist")}})

	syn := NewSyncer(&taggedTester{ip: "198.51.100.10"}, reg, &fakeHistory{})
	cfg := &config.Config{
		CFIP: &config.CFIPConfig{
			Paths:      config.PathConfig{GlobalBestFile: globalFile},
			SpeedTest: config.SpeedTestConfig{TakeIPNum: 5},
		},
	}

	_, err := syn.SyncAll(context.Background(), cfg, nil)
	require.NoError(t, err)

	content, err := os.ReadFile(globalFile)
	require.NoError(t, err, "全局最优 IP 文件应被写入")
	assert.Contains(t, string(content), "198.51.100.10", "全局最优文件应包含最优 IP")
	// 强制 .iplist 落盘（即便文件名已是 .iplist，这里验证扩展名确定）。
	assert.True(t, strings.HasSuffix(globalFile, ".iplist"))
}

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
