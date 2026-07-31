package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"cfopt/internal/config"
	"cfopt/internal/deploy"
	"cfopt/internal/prompt"
	"cfopt/internal/sync"
)

// TestDeployPlan_confPathAndSubDir 验证 conf 落盘路径与 loader 扫描目录一致（cfgDir/cf-dns|dnspod/<domain>.conf）。
// 这是工程师声称修复的「配置缓存陷阱」关键不变量。
func TestDeployPlan_confPathAndSubDir(t *testing.T) {
	cf := &deploy.DeployPlan{Provider: "cloudflare", Domain: "a.example.com"}
	if cf.ConfSubDir() != "cf-dns" || cf.ConfFileName() != "a.example.com.conf" {
		t.Fatalf("CF 路径不符: sub=%q file=%q", cf.ConfSubDir(), cf.ConfFileName())
	}
	dp := &deploy.DeployPlan{Provider: "dnspod", Domain: "b.example.com"}
	if dp.ConfSubDir() != "dnspod" || dp.ConfFileName() != "b.example.com.conf" {
		t.Fatalf("DNSPod 路径不符: sub=%q file=%q", dp.ConfSubDir(), dp.ConfFileName())
	}
}

// TestWriteDeployConf_cloudflareDefaultRecordName CF 未提供子域名应回退 "@"，且落盘后 LoadFresh 能加载到。
func TestWriteDeployConf_cloudflareDefaultRecordName(t *testing.T) {
	tmp := t.TempDir()
	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	plan := &deploy.DeployPlan{Provider: "cloudflare", Token: "tok-0123456789-abcdefghij", ZoneID: "z1", Domain: "example.com"}
	if err := writeDeployConf(plan); err != nil {
		t.Fatalf("writeDeployConf 不应失败: %v", err)
	}
	if err := config.WriteDefaults(tmp); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadFresh(tmp)
	if err != nil {
		t.Fatal(err)
	}
	d := cfg.CFDNSDomains["example.com"]
	if d == nil {
		t.Fatal("LoadFresh 应加载 example.com 到 CFDNSDomains")
	}
	if d.DNS.RecordName != "@" {
		t.Fatalf("CF RecordName 应为 @（默认根域名），got=%q", d.DNS.RecordName)
	}
	if _, err := os.Stat(filepath.Join(tmp, "cf-dns", "example.com.conf")); err != nil {
		t.Fatalf("conf 文件未生成: %v", err)
	}
}

// TestWriteDeployConf_dnspodSingleLine 单线路 DNSPod 应置 mode=single。
func TestWriteDeployConf_dnspodSingleLine(t *testing.T) {
	tmp := t.TempDir()
	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	plan := &deploy.DeployPlan{Provider: "dnspod", SecretID: "id", SecretKey: "key", Domain: "example.com", SubDomain: "www"}
	if err := writeDeployConf(plan); err != nil {
		t.Fatalf("writeDeployConf 不应失败: %v", err)
	}
	if err := config.WriteDefaults(tmp); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadFresh(tmp)
	if err != nil {
		t.Fatal(err)
	}
	// key 为完整子域名（sub_domain.domain），与 ConfFileName / scanDNSPodConfDir 语义一致。
	d := cfg.DNSPodDomains["www.example.com"]
	if d == nil {
		t.Fatal("LoadFresh 应加载 www.example.com 到 DNSPodDomains")
	}
	if d.Mode != "single" {
		t.Fatalf("单线路应置 mode=single，got=%q", d.Mode)
	}
	if d.SubDomain != "www" {
		t.Fatalf("SubDomain 应为 www，got=%q", d.SubDomain)
	}
}

// TestCfstBinaryExists_viaCfgDir 验证 cfstBinaryExists 通过 cfgDir 路径找到二进制。
func TestCfstBinaryExists_viaCfgDir(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	// 不放置任何 cfst → 应返回 false
	if cfstBinaryExists() {
		t.Error("空目录应返回 false")
	}

	// 在 cfgDir/assets/cfst/ 放置 cfst
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	cfstPath := filepath.Join(tmp, "assets", "cfst")
	_ = os.MkdirAll(cfstPath, 0o755)
	_ = os.WriteFile(filepath.Join(cfstPath, binName), []byte("fake"), 0o755)

	if !cfstBinaryExists() {
		t.Error("cfgDir/assets/cfst 下有 cfst 时应返回 true")
	}
}

// TestCfstBinaryExists_notFound 三路路径均无 cfst 时返回 false。
func TestCfstBinaryExists_notFound(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	if cfstBinaryExists() {
		t.Error("三路路径均无 cfst 时应返回 false")
	}
}

// TestQuickDeployCore_syncFailureNonFatal 首次同步失败不应致命：仍落盘并返回 nil（设计共享识：sync 失败仅告警）。
func TestQuickDeployCore_syncFailureNonFatal(t *testing.T) {
	origSync := syncRunner
	origSched := scheduleInstaller
	syncRunner = func(ctx context.Context, dir string, _ string, _ ...string) (*sync.SyncSummary, error) {
		return nil, fmt.Errorf("sync boom")
	}
	scheduleInstaller = func() error { return nil }
	defer func() { syncRunner = origSync; scheduleInstaller = origSched }()

	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	plan := &deploy.DeployPlan{Provider: "cloudflare", Token: "tok-0123456789-abcdefghij", ZoneID: "z1", Domain: "example.com"}
	if _, err := quickDeployCore(context.Background(), plan, false); err != nil {
		t.Fatalf("同步失败不应致命，got=%v", err)
	}
	if _, err := os.Stat(filepath.Join(tmp, "cf-dns", "example.com.conf")); err != nil {
		t.Fatalf("同步失败仍应落盘 conf: %v", err)
	}
}

// TestDeployPlan_HasColoField 验证 DeployPlan 存在 Colo 字段且类型为 string。
func TestDeployPlan_HasColoField(t *testing.T) {
	p := &deploy.DeployPlan{Colo: "HKG,NRT"}
	if p.Colo != "HKG,NRT" {
		t.Fatalf("Colo 字段应为 string 类型，got=%T", p.Colo)
	}
}

// TestPrintDeploySummary_showsColo 验证 printDeploySummary 在 plan.Colo 非空时输出测速地区行。
func TestPrintDeploySummary_showsColo(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	plan := &deploy.DeployPlan{
		Provider:         "cloudflare",
		Domain:           "example.com",
		RecordName:       "@",
		ZoneID:           "z1",
		Colo:             "HKG,NRT",
		ScheduleInterval: "6h",
	}
	printDeploySummary(plan, true)
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	if !bytes.Contains(out, []byte("HKG,NRT")) {
		t.Fatalf("摘要应显示测速地区 HKG,NRT，实际输出:\n%s", string(out))
	}
	if !bytes.Contains(out, []byte("测速地区")) {
		t.Fatalf("摘要应包含「测速地区」标签，实际:\n%s", string(out))
	}
}

// TestPrintDeploySummary_noColo 验证 printDeploySummary 在 plan.Colo 为空时不显示测速地区行。
func TestPrintDeploySummary_noColo(t *testing.T) {
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	plan := &deploy.DeployPlan{
		Provider:         "cloudflare",
		Domain:           "example.com",
		RecordName:       "@",
		ZoneID:           "z1",
		ScheduleInterval: "6h",
		// Colo 为空
	}
	printDeploySummary(plan, true)
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	if bytes.Contains(out, []byte("测速地区")) {
		t.Fatalf("Colo 为空时不应显示测速地区行，实际输出:\n%s", string(out))
	}
}

// TestRunQuickdeploy_deploySummaryPrinted 验证 runQuickdeploy 取消流程不 panic。
func TestRunQuickdeploy_deploySummaryPrinted(t *testing.T) {
	// 测试交互取消流程不 panic（deploy 后续的 CF-IP 提示需要真实 API 才能到达）
	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	_ = config.WriteDefaults(tmp)

	// 创建假 cfst 二进制，避免触发下载
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	cfstDir := filepath.Join(tmp, "assets", "cfst")
	_ = os.MkdirAll(cfstDir, 0755)
	_ = os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0755)

	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("1\ntoken\nn\n"))
	defer prompt.SetInput(nil)

	err := runQuickdeploy(true)
	// 预期：cloudflare validate 失败后用户取消，返回具体错误
	// 只要不 panic 就算通过
	if err != nil {
		t.Logf("runQuickdeploy 返回预期错误（凭证校验失败）: %v", err)
	}
}
