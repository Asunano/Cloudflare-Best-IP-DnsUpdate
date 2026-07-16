package sync

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// ---------------------------------------------------------------------------
// mocks
// ---------------------------------------------------------------------------

// fakeTester 直接返回一条有效测速结果（无需真实 cfst 二进制）。
type fakeTester struct{}

func (fakeTester) Run(ctx context.Context, cfg *config.CFIPConfig) ([]speedtest.SpeedResult, error) {
	return []speedtest.SpeedResult{{IP: "1.2.3.4", Latency: 10, Speed: 100, Colo: "HKG"}}, nil
}
func (fakeTester) ParseOutput(path string) ([]speedtest.SpeedResult, error) { return nil, nil }
func (fakeTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{IP: r.IP, Latency: r.Latency, Speed: r.Speed, Colo: r.Colo})
	}
	return recs
}

// fakeHistory 内存态历史存储，记录 Append 调用。
type fakeHistory struct {
	entries []history.HistoryEntry
}

func (h *fakeHistory) Append(e history.HistoryEntry) error {
	h.entries = append(h.entries, e)
	return nil
}
func (h *fakeHistory) ReadLatest(n int) ([]history.HistoryEntry, error) { return h.entries, nil }

// fakeModule 可挂载 SyncModule 的受控实现，记录 Sync 调用次数与返回结果。
type fakeModule struct {
	id      string
	enabled bool
	files   []string
	res     *dns.SyncResult
	err     error
	synced  int
}

func (m *fakeModule) ID() string                                { return m.id }
func (m *fakeModule) Enabled(cfg *config.Config) bool           { return m.enabled }
func (m *fakeModule) IPSourceFiles(cfg *config.Config) []string { return m.files }
func (m *fakeModule) Sync(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	m.synced++
	if m.res == nil {
		m.res = &dns.SyncResult{}
	}
	return m.res, m.err
}

// ---------------------------------------------------------------------------
// 用例：SyncAll 遍历 / providers 过滤 / 历史 / 阶段计数
// ---------------------------------------------------------------------------

// TestSyncAll_TraverseAll 验证全部启用模块均被遍历、结果累加、历史以 sync.<id> 写入。
func TestSyncAll_TraverseAll(t *testing.T) {
	reg := dns.NewRegistry()
	m1 := &fakeModule{id: "a", enabled: true, res: &dns.SyncResult{Updated: 1}}
	m2 := &fakeModule{id: "b", enabled: true, res: &dns.SyncResult{Created: 2}}
	reg.RegisterAll([]dns.SyncModule{m1, m2})

	hist := &fakeHistory{}
	syn := NewSyncer(fakeTester{}, reg, hist)
	summary, err := syn.SyncAll(context.Background(), &config.Config{}, nil)
	require.NoError(t, err)

	assert.Equal(t, 1, m1.synced)
	assert.Equal(t, 1, m2.synced)

	// 历史：sync.a / sync.b，按遍历顺序。
	require.Len(t, hist.entries, 2)
	assert.Equal(t, "sync.a", hist.entries[0].Action)
	assert.Equal(t, "sync.b", hist.entries[1].Action)
	assert.True(t, hist.entries[0].Success)
	assert.True(t, hist.entries[1].Success)

	// 汇总累加。
	assert.Equal(t, 1, summary.Updated)
	assert.Equal(t, 2, summary.Created)
}

// TestSyncAll_ProvidersFilter 验证 providers 非空时仅指定且启用的模块被调用。
func TestSyncAll_ProvidersFilter(t *testing.T) {
	reg := dns.NewRegistry()
	m1 := &fakeModule{id: "a", enabled: true}
	m2 := &fakeModule{id: "b", enabled: true}
	reg.RegisterAll([]dns.SyncModule{m1, m2})

	syn := NewSyncer(fakeTester{}, reg, &fakeHistory{})
	_, err := syn.SyncAll(context.Background(), &config.Config{}, nil, "a")
	require.NoError(t, err)

	assert.Equal(t, 1, m1.synced, "a 应被调用")
	assert.Equal(t, 0, m2.synced, "b 不应被调用（不在 providers 中）")
}

// TestSyncAll_EnabledSkipped 验证未启用模块即使未指定 providers 也被跳过。
func TestSyncAll_EnabledSkipped(t *testing.T) {
	reg := dns.NewRegistry()
	m1 := &fakeModule{id: "a", enabled: false}
	m2 := &fakeModule{id: "b", enabled: true}
	reg.RegisterAll([]dns.SyncModule{m1, m2})

	syn := NewSyncer(fakeTester{}, reg, &fakeHistory{})
	_, err := syn.SyncAll(context.Background(), &config.Config{}, nil)
	require.NoError(t, err)

	assert.Equal(t, 0, m1.synced, "a 未启用，跳过")
	assert.Equal(t, 1, m2.synced, "b 启用，调用")
}

// TestSyncAll_PhaseCount 验证进度阶段顺序与总数 = 3 + 启用模块数。
func TestSyncAll_PhaseCount(t *testing.T) {
	reg := dns.NewRegistry()
	m1 := &fakeModule{id: "a", enabled: true}
	m2 := &fakeModule{id: "b", enabled: true}
	reg.RegisterAll([]dns.SyncModule{m1, m2})

	syn := NewSyncer(fakeTester{}, reg, &fakeHistory{})
	var phases []string
	var lastCur, lastTotal int
	_, err := syn.SyncAll(context.Background(), &config.Config{}, func(phase string, cur, total int) {
		phases = append(phases, phase)
		lastCur = cur
		lastTotal = total
	})
	require.NoError(t, err)

	assert.Equal(t, []string{"speedtest", "extract", "write", "a", "b"}, phases)
	assert.Equal(t, 5, lastTotal, "总数应为 3 + 2 个启用模块")
	assert.Equal(t, 5, lastCur)
}

// TestSyncAll_ProvidersWithError 验证某模块 Sync 报错时返回错误且计入 Errors。
func TestSyncAll_ProvidersWithError(t *testing.T) {
	reg := dns.NewRegistry()
	m1 := &fakeModule{id: "a", enabled: true, err: assertErr("boom")}
	reg.RegisterAll([]dns.SyncModule{m1})

	syn := NewSyncer(fakeTester{}, reg, &fakeHistory{})
	_, err := syn.SyncAll(context.Background(), &config.Config{}, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "boom")
}

type assertError string

func (e assertError) Error() string { return string(e) }

// 便于在用例中构造错误。
func assertErr(s string) error { return assertError(s) }
