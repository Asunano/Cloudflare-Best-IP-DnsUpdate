package cmd

import (
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
	"cfopt/internal/sync"
)

func TestWriteDeployConf_cloudflare(t *testing.T) {
	tmp := t.TempDir()
	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	plan := &deploy.DeployPlan{
		Provider:   "cloudflare",
		Token:      "tok-0123456789-abcdefghij",
		ZoneID:     "zone-1",
		Domain:     "example.com",
		RecordName: "www",
	}
	if err := writeDeployConf(plan); err != nil {
		t.Fatalf("writeDeployConf 不应失败: %v", err)
	}
	p := filepath.Join(tmp, "cf-dns", "example.com.conf")
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatalf("conf 文件未生成: %v", err)
	}
	// 权限 0600 是 Unix 语义；Windows 不映射 Unix 权限位，仅在校验存在性。
	if runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Fatalf("conf 权限应为 0600，got %o", fi.Mode().Perm())
	}
	// LoadFresh 应能读到新域名配置。
	if err := config.WriteDefaults(tmp); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadFresh(tmp)
	if err != nil {
		t.Fatalf("LoadFresh 不应失败: %v", err)
	}
	d, ok := cfg.CFDNSDomains["example.com"]
	if !ok {
		t.Fatal("LoadFresh 应加载 example.com 到 CFDNSDomains")
	}
	if d.API.Token != plan.Token || d.API.ZoneID != plan.ZoneID {
		t.Fatalf("加载的 conf 字段不符: %+v", d)
	}
}

func TestWriteDeployConf_dnspodMultiLine(t *testing.T) {
	tmp := t.TempDir()
	orig := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = orig }()

	plan := &deploy.DeployPlan{
		Provider:  "dnspod",
		SecretID:  "id",
		SecretKey: "key",
		Domain:    "example.com",
		SubDomain: "www",
		Lines:     []string{"默认", "联通", "电信"},
	}
	if err := writeDeployConf(plan); err != nil {
		t.Fatalf("writeDeployConf 不应失败: %v", err)
	}
	if err := config.WriteDefaults(tmp); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadFresh(tmp)
	if err != nil {
		t.Fatalf("LoadFresh 不应失败: %v", err)
	}
	d, ok := cfg.DNSPodDomains["example.com"]
	if !ok {
		t.Fatal("LoadFresh 应加载 example.com 到 DNSPodDomains")
	}
	if d.Mode != "isp_lines" {
		t.Fatalf("多线路应置 mode=isp_lines，got %q", d.Mode)
	}
	if len(d.ISP) != 3 {
		t.Fatalf("ISP 应含 3 条线路，got %d", len(d.ISP))
	}
}

func TestQuickDeployCore_orchestration(t *testing.T) {
	// 桩：同步与调度均为 no-op，避免依赖真实 cfst/网络/系统服务。
	origSync := syncRunner
	origSched := scheduleInstaller
	syncRunner = func(ctx context.Context, dir string) (*sync.SyncSummary, error) {
		return &sync.SyncSummary{BestIPCount: 3}, nil
	}
	scheduled := false
	scheduleInstaller = func() error { scheduled = true; return nil }
	defer func() { syncRunner = origSync; scheduleInstaller = origSched }()

	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	plan := &deploy.DeployPlan{
		Provider:         "cloudflare",
		Token:            "tok-0123456789-abcdefghij",
		ZoneID:           "zone-1",
		Domain:           "example.com",
		RecordName:       "www",
		ScheduleInterval: "6h",
	}
	scheduleInstalled, err := quickDeployCore(context.Background(), plan, true)
	if err != nil {
		t.Fatalf("quickDeployCore 不应失败: %v", err)
	}
	p := filepath.Join(tmp, "cf-dns", "example.com.conf")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("conf 文件未生成: %v", err)
	}
	if !scheduled {
		t.Error("installSchedule=true 时应调用调度安装器")
	}
	if !scheduleInstalled {
		t.Error("installSchedule=true 且调度成功时应返回 scheduleInstalled=true（4b）")
	}
	// LoadFresh 应看到新域名。
	cfg, err := config.LoadFresh(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg.CFDNSDomains["example.com"]; !ok {
		t.Error("调度后 LoadFresh 应能看到新域名")
	}
}

func TestQuickDeployCore_noSchedule(t *testing.T) {
	origSync := syncRunner
	origSched := scheduleInstaller
	syncRunner = func(ctx context.Context, dir string) (*sync.SyncSummary, error) { return &sync.SyncSummary{}, nil }
	scheduled := false
	scheduleInstaller = func() error { scheduled = true; return nil }
	defer func() { syncRunner = origSync; scheduleInstaller = origSched }()

	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	plan := &deploy.DeployPlan{Provider: "dnspod", SecretID: "id", SecretKey: "key", Domain: "x.com", SubDomain: "www"}
	scheduleInstalled, err := quickDeployCore(context.Background(), plan, false)
	if err != nil {
		t.Fatalf("quickDeployCore 不应失败: %v", err)
	}
	if scheduled {
		t.Error("installSchedule=false 时不应安装调度")
	}
	if scheduleInstalled {
		t.Error("installSchedule=false 时 scheduleInstalled 应为 false（4b）")
	}
}

// TestQuickDeployCore_syncFailureCfstHint 同步失败含 "cfst" 时应打印 📌 醒目提示（4c）。
func TestQuickDeployCore_syncFailureCfstHint(t *testing.T) {
	origSync := syncRunner
	origSched := scheduleInstaller
	syncRunner = func(ctx context.Context, dir string) (*sync.SyncSummary, error) {
		return nil, fmt.Errorf("cfst binary not found")
	}
	scheduleInstaller = func() error { return nil }
	defer func() { syncRunner = origSync; scheduleInstaller = origSched }()

	tmp := t.TempDir()
	origCfg := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfg }()

	// 捕获 stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	plan := &deploy.DeployPlan{Provider: "cloudflare", Token: "tok-0123456789-abcdefghij", ZoneID: "z1", Domain: "example.com"}
	if _, err := quickDeployCore(context.Background(), plan, false); err != nil {
		t.Fatalf("quickDeployCore 不应致命: %v", err)
	}
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	s := string(out)
	if !strings.Contains(s, "📌") {
		t.Errorf("同步失败含 cfst 时应打印 📌 提示，实际输出:\n%s", s)
	}
	if !strings.Contains(s, "cfst") {
		t.Errorf("同步失败含 cfst 时应包含 cfst 字样:\n%s", s)
	}
}
