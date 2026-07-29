package sync

// 二次检测补充测试（独立视角）：证明 P0-2「多线路真正分流」。
//
// 现有 TestSyncAll_PerLineSkipsGlobalWrite 仅用「单线路 + 全局 best」验证“跳过全局 best”，
// 并未证明“不同线路最终落盘不同 IP 集”。本文件补齐该缺口：构造多线路模块，
// 让每条线路经各自测速得到不同 IP，断言各线路 IP 文件内容互不相同、互不包含对方 IP、
// 且不被全局 best 覆盖。

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// lineFromOutputDir 从 per-line 输出目录（.../perline/<line>）提取线路名。
func lineFromOutputDir(dir string) string {
	marker := "perline" + string(filepath.Separator)
	if idx := strings.LastIndex(dir, marker); idx >= 0 {
		return dir[idx+len(marker):]
	}
	// 退化处理（理论上不会触发）。
	if idx := strings.LastIndex(dir, "perline"); idx >= 0 {
		return dir[idx+len("perline"):]
	}
	return ""
}

// multiLineTaggedTester 按 OutputDir 末尾线路名返回该线路专属 IP。
type multiLineTaggedTester struct {
	ipByLine map[string]string
}

func (t *multiLineTaggedTester) Run(_ context.Context, cfg *config.CFIPConfig, _ speedtest.ProgressFunc) ([]speedtest.SpeedResult, error) {
	line := lineFromOutputDir(cfg.Paths.OutputDir)
	ip := t.ipByLine[line]
	if ip == "" {
		ip = "203.0.113.1"
	}
	return []speedtest.SpeedResult{{IP: ip, Latency: 10, Speed: 100, Colo: "HKG"}}, nil
}
func (t *multiLineTaggedTester) ParseOutput(_ string) ([]speedtest.SpeedResult, error) { return nil, nil }
func (t *multiLineTaggedTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{IP: r.IP, Latency: r.Latency, Speed: r.Speed, Colo: r.Colo})
	}
	return recs
}

// fakeMultiLineModule 多线路模块：实现 SyncModule + PerLineSpeedtester，
// 每条线路有自己的 IP 文件与专属测速 IP。
type fakeMultiLineModule struct {
	id      string
	perLine map[string]string // line -> ip 文件
}

func (m *fakeMultiLineModule) ID() string                                       { return m.id }
func (m *fakeMultiLineModule) Enabled(cfg *config.Config) bool                  { return true }
func (m *fakeMultiLineModule) IPSourceFiles(cfg *config.Config) []string {
	var fs []string
	for _, f := range m.perLine {
		fs = append(fs, f)
	}
	return fs
}
func (m *fakeMultiLineModule) Sync(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	return &dns.SyncResult{}, nil
}
func (m *fakeMultiLineModule) UsePerLineSpeedtest(cfg *config.Config) bool { return true }
func (m *fakeMultiLineModule) SpeedtestJobs(cfg *config.Config) []dns.LineSpeedtestJob {
	lines := make([]string, 0, len(m.perLine))
	for line := range m.perLine {
		lines = append(lines, line)
	}
	sort.Strings(lines)
	jobs := make([]dns.LineSpeedtestJob, 0, len(lines))
	for _, line := range lines {
		jobs = append(jobs, dns.LineSpeedtestJob{
			Line:      line,
			IPFiles:   []string{m.perLine[line]},
			SubDomain: "www",
		})
	}
	return jobs
}

// TestSyncAll_PerLineDivergentIPs 验证不同线路真正分流（P0-2 核心不变量）：
// 各线路专属 IP 落盘到各自文件，彼此内容不同、互不包含对方 IP（无交叉污染）、
// 且不被全局 best 覆盖。
func TestSyncAll_PerLineDivergentIPs(t *testing.T) {
	dir := t.TempDir()

	wantIP := map[string]string{
		"联通": "203.0.113.11",
		"移动": "203.0.113.22",
		"电信": "203.0.113.33",
	}
	ipFiles := map[string]string{}
	for line := range wantIP {
		ipFiles[line] = filepath.Join(dir, "perline-"+line+".iplist")
	}

	mod := &fakeMultiLineModule{id: "pl", perLine: ipFiles}
	reg := dns.NewRegistry()
	reg.Register(mod)

	// 全局 best（仅占位；per-line 模块不应被其覆盖）。
	const globalBest = "198.51.100.10"

	// 工厂依据 OutputDir 末尾线路名返回该线路专属 IP。
	syn := NewSyncer(&taggedTester{ip: globalBest}, reg, &fakeHistory{})
	syn.perLineTesterFactory = func(c *config.CFIPConfig) (speedtest.SpeedTester, error) {
		return &multiLineTaggedTester{ipByLine: wantIP}, nil
	}

	cfg := &config.Config{
		CFIP: &config.CFIPConfig{
			Paths:      config.PathConfig{OutputDir: filepath.Join(dir, "out")},
			SpeedTest: config.SpeedTestConfig{TakeIPNum: 5},
		},
	}

	_, err := syn.SyncAll(context.Background(), cfg, nil)
	require.NoError(t, err)

	// 逐线路落盘内容应各自包含其专属 IP，且不被全局 best 覆盖。
	written := map[string]string{}
	for line, f := range ipFiles {
		content, rerr := os.ReadFile(f)
		require.NoError(t, rerr, "线路 %s 的 IP 文件应被写入", line)
		written[line] = string(content)
		assert.Contains(t, string(content), wantIP[line], "线路 %s 应落盘其专属 IP %s", line, wantIP[line])
		assert.NotContains(t, string(content), globalBest, "线路 %s 文件不应被全局 best 覆盖", line)
	}

	// 交叉污染检测：任一线路文件都不应包含其它线路的专属 IP（真正分流）。
	for line, content := range written {
		for otherLine, otherIP := range wantIP {
			if otherLine == line {
				continue
			}
			assert.NotContains(t, content, otherIP,
				"线路 %s 文件不应包含线路 %s 的专属 IP %s（真正分流，无交叉污染）", line, otherLine, otherIP)
		}
	}

	// 三份文件内容彼此不同（真正分流，而非同一份复制）。
	assert.NotEqual(t, written["联通"], written["移动"], "联通与移动文件内容应不同")
	assert.NotEqual(t, written["联通"], written["电信"], "联通与电信文件内容应不同")
	assert.NotEqual(t, written["移动"], written["电信"], "移动与电信文件内容应不同")
}
