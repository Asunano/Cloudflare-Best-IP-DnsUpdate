package sync

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// captureTester 记录每次 Run 调用时使用的 colo，用于验证按域名独立测速。
type captureTester struct {
	calls    int
	colos    []string
	results  []speedtest.SpeedResult
}

func (c *captureTester) Run(ctx context.Context, cfg *config.CFIPConfig, progress speedtest.ProgressFunc) ([]speedtest.SpeedResult, error) {
	c.calls++
	c.colos = append(c.colos, cfg.CFST.Colo)
	return c.results, nil
}
func (c *captureTester) ParseOutput(path string) ([]speedtest.SpeedResult, error) { return nil, nil }
func (c *captureTester) ToIPList(results []speedtest.SpeedResult) []ipsource.IPRecord {
	return nil
}

// failTester 记录调用次数、按序返回预设错误，用于验证自动重测逻辑。
// 需实现 SpeedTester 接口的全部方法（Run/ParseOutput/ToIPList）。
type failTester struct {
	calls   int
	failN   int // 前 failN 次返回 err
	err     error
	results []speedtest.SpeedResult
}

func (f *failTester) Run(ctx context.Context, cfg *config.CFIPConfig, progress speedtest.ProgressFunc) ([]speedtest.SpeedResult, error) {
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

// TestRunPerDomainSpeedtest_WritesPerDomainFile 验证：配置了 SpeedTestColo 的域名
// 会以该 colo 独立测速并写入其专属 IP 文件。
func TestRunPerDomainSpeedtest_WritesPerDomainFile(t *testing.T) {
	outDir := t.TempDir()
	ipFile := filepath.Join(outDir, "example.com.iplist")
	cfg := &config.Config{
		CFIP: &config.CFIPConfig{
			SpeedTest: config.SpeedTestConfig{MaxRetry: 1, TakeIPNum: 2},
			Paths:     config.PathConfig{OutputDir: outDir},
		},
		CFDNSDomains: map[string]*config.CFDNSConfig{
			"example.com": {
				Enabled:  true,
				DNS:      config.CloudflareDNSConfig{Domain: "example.com"},
				IPSource: config.CloudflareIPSourceConfig{FilePath: ipFile},
				SpeedTestColo: "HKG",
			},
		},
	}
	ct := &captureTester{results: []speedtest.SpeedResult{{IP: "1.2.3.4"}, {IP: "5.6.7.8"}}}
	s := &Syncer{tester: ct, perLineTesterFactory: func(c *config.CFIPConfig) (speedtest.SpeedTester, error) { return ct, nil }}

	require.NoError(t, s.runPerDomainSpeedtest(context.Background(), cfg))
	assert.Contains(t, ct.colos, "HKG", "应以域名的 colo 触发测速")
	recs, rerr := ipsource.Read(ipFile)
	require.NoError(t, rerr)
	assert.Len(t, recs, 2, "应写入该域名的 IP 文件")
}

// TestRunPerDomainSpeedtest_NoColoNoOp 验证：无域名配置 colo 时不触发额外测速（零回归）。
func TestRunPerDomainSpeedtest_NoColoNoOp(t *testing.T) {
	cfg := &config.Config{
		CFIP: &config.CFIPConfig{SpeedTest: config.SpeedTestConfig{MaxRetry: 1}},
		CFDNSDomains: map[string]*config.CFDNSConfig{
			"example.com": {
				Enabled:  true,
				DNS:      config.CloudflareDNSConfig{Domain: "example.com"},
				IPSource: config.CloudflareIPSourceConfig{FilePath: filepath.Join(t.TempDir(), "x.iplist")},
			},
		},
	}
	ct := &captureTester{results: []speedtest.SpeedResult{{IP: "1.1.1.1"}}}
	s := &Syncer{tester: ct, perLineTesterFactory: func(c *config.CFIPConfig) (speedtest.SpeedTester, error) { return ct, nil }}

	require.NoError(t, s.runPerDomainSpeedtest(context.Background(), cfg))
	assert.Empty(t, ct.colos, "无 colo 不应触发额外测速")
}
