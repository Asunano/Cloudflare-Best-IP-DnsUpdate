package cmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"cfopt/internal/prompt"
)

// ============================================================================
// F1+P2: Health check dashboard + auto-fix (health.go)
// ============================================================================

// TestRunAllChecks_returnsSix verifies runAllChecks returns exactly 6 items.
func TestRunAllChecks_returnsSix(t *testing.T) {
	issues := runAllChecks()
	if len(issues) != 6 {
		t.Fatalf("runAllChecks should return 6 items, got %d", len(issues))
	}
	for i, iss := range issues {
		if iss.Name == "" {
			t.Errorf("issues[%d].Name is empty", i)
		}
		if iss.Status != "ok" && iss.Status != "fail" {
			t.Errorf("issues[%d].Status should be ok/fail, got %q", i, iss.Status)
		}
	}
}

// TestRunAllChecks_names verifies the 6 check names and order.
func TestRunAllChecks_names(t *testing.T) {
	issues := runAllChecks()
	wantNames := []string{
		"cfst 二进制",
		"配置文件",
		"数据目录",
		"网络连接",
		"调度服务",
		"历史错误",
	}
	for i, want := range wantNames {
		if issues[i].Name != want {
			t.Errorf("issues[%d].Name = %q, want %q", i, issues[i].Name, want)
		}
	}
}

// TestCheckCFSTBinary_withBinary presets a fake cfst binary and expects ok.
func TestCheckCFSTBinary_withBinary(t *testing.T) {
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	cfstDir := filepath.Join(cfgDir, "assets", "cfst")
	if err := os.MkdirAll(cfstDir, 0o755); err != nil {
		t.Fatal(err)
	}
	binPath := filepath.Join(cfstDir, binName)
	if err := os.WriteFile(binPath, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(filepath.Join(cfgDir, "assets"))

	iss := checkCFSTBinary()
	if iss.Status != "ok" {
		t.Fatalf("with binary should return ok, got status=%q detail=%q", iss.Status, iss.Detail)
	}
	if !strings.Contains(iss.Detail, "\u5c31\u7eea") { // 就绪
		t.Errorf("Detail should contain [就绪], got %q", iss.Detail)
	}
	if !iss.fixable {
		t.Error("cfst check should be fixable")
	}
}

// TestCheckCFSTBinary_withoutBinary expects fail and fix suggestion.
func TestCheckCFSTBinary_withoutBinary(t *testing.T) {
	origCfgDir := cfgDir
	defer func() { cfgDir = origCfgDir }()
	tmp := t.TempDir()
	cfgDir = tmp

	iss := checkCFSTBinary()
	if iss.Status != "fail" {
		t.Fatalf("without binary should return fail, got status=%q", iss.Status)
	}
	if !strings.Contains(iss.Detail, "\u7f3a\u5931") { // 缺失
		t.Errorf("Detail should contain [缺失], got %q", iss.Detail)
	}
	if !strings.Contains(iss.Fix, "cfst fetch") {
		t.Errorf("Fix should mention cfst fetch, got %q", iss.Fix)
	}
}

// TestCheckConfigFiles_allPresent all config files + .conf dirs -> ok.
func TestCheckConfigFiles_allPresent(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	for _, f := range []string{"global.json", "cf-dns.json", "dnspod.json"} {
		if err := os.WriteFile(filepath.Join(tmp, f), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfDNSDir := filepath.Join(tmp, "cf-dns")
	if err := os.MkdirAll(cfDNSDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfDNSDir, "example.com.conf"), []byte(`{"dns":{"domain":"example.com"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	dnspodDir := filepath.Join(tmp, "dnspod")
	if err := os.MkdirAll(dnspodDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dnspodDir, "example.conf"), []byte(`{"domain":"example.com"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	iss := checkConfigFiles()
	if iss.Status != "ok" {
		t.Fatalf("all config present should return ok, got status=%q detail=%q", iss.Status, iss.Detail)
	}
}

// TestCheckConfigFiles_missingJSON missing JSON files -> fail.
func TestCheckConfigFiles_missingJSON(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	if err := os.WriteFile(filepath.Join(tmp, "global.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "cf-dns.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	iss := checkConfigFiles()
	if iss.Status != "fail" {
		t.Fatalf("missing config should return fail, got status=%q detail=%q", iss.Status, iss.Detail)
	}
	if !strings.Contains(iss.Detail, "\u7f3a\u5931") { // 缺失
		t.Errorf("Detail should contain [缺失], got %q", iss.Detail)
	}
	if !strings.Contains(iss.Fix, "config init") {
		t.Errorf("Fix should mention config init, got %q", iss.Fix)
	}
}

// TestCheckConfigFiles_missingConfDirs JSON present but no .conf dirs -> ok.
func TestCheckConfigFiles_missingConfDirs(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	for _, f := range []string{"global.json", "cf-dns.json", "dnspod.json"} {
		if err := os.WriteFile(filepath.Join(tmp, f), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	iss := checkConfigFiles()
	if iss.Status != "ok" {
		t.Fatalf("JSON complete without .conf should return ok, got status=%q", iss.Status)
	}
}

// TestCheckDataDirs_writable writable data dirs -> ok.
func TestCheckDataDirs_writable(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	iss := checkDataDirs()
	if iss.Status != "ok" {
		t.Fatalf("writable dirs should return ok, got status=%q detail=%q", iss.Status, iss.Detail)
	}
	if !strings.Contains(iss.Detail, "\u53ef\u5199") { // 可写
		t.Errorf("Detail should contain [可写], got %q", iss.Detail)
	}
	if iss.fixable {
		t.Error("data dirs check should NOT be fixable")
	}
}

// TestCheckHistoryErrors_noHistory no history file -> ok.
func TestCheckHistoryErrors_noHistory(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	iss := checkHistoryErrors()
	if iss.Status != "ok" {
		t.Fatalf("no history should return ok, got status=%q detail=%q", iss.Status, iss.Detail)
	}
	if !strings.Contains(iss.Detail, "\u65e0\u5386\u53f2") { // 无历史
		t.Errorf("Detail should contain [无历史], got %q", iss.Detail)
	}
}

// TestCheckHistoryErrors_cleanHistory history without errors -> ok.
func TestCheckHistoryErrors_cleanHistory(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	histDir := filepath.Join(tmp, "assets", "data")
	if err := os.MkdirAll(histDir, 0o755); err != nil {
		t.Fatal(err)
	}
	histPath := filepath.Join(histDir, "history.jsonl")
	lines := []string{
		`{"timestamp":"2025-01-01T00:00:00Z","action":"sync","success":true,"detail":"ok"}`,
		`{"timestamp":"2025-01-01T01:00:00Z","action":"sync","success":true,"detail":"ok"}`,
	}
	if err := os.WriteFile(histPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	iss := checkHistoryErrors()
	if iss.Status != "ok" {
		t.Fatalf("clean history should return ok, got status=%q detail=%q", iss.Status, iss.Detail)
	}
}

// TestCheckHistoryErrors_withErrors history with errors -> fail.
func TestCheckHistoryErrors_withErrors(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	histDir := filepath.Join(tmp, "assets", "data")
	if err := os.MkdirAll(histDir, 0o755); err != nil {
		t.Fatal(err)
	}
	histPath := filepath.Join(histDir, "history.jsonl")
	lines := []string{
		`{"timestamp":"2025-01-01T00:00:00Z","action":"sync","success":true,"detail":"ok"}`,
		`{"timestamp":"2025-01-01T01:00:00Z","action":"sync","success":false,"detail":"timeout error"}`,
	}
	if err := os.WriteFile(histPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	iss := checkHistoryErrors()
	if iss.Status != "fail" {
		t.Fatalf("history with errors should return fail, got status=%q detail=%q", iss.Status, iss.Detail)
	}
	if !strings.Contains(iss.Detail, "\u9519\u8bef") { // 错误
		t.Errorf("Detail should contain [错误], got %q", iss.Detail)
	}
	if !strings.Contains(iss.Fix, "schedule status") {
		t.Errorf("Fix should mention schedule status, got %q", iss.Fix)
	}
}

// TestCheckScheduleStatus_fixable schedule check is fixable.
func TestCheckScheduleStatus_fixable(t *testing.T) {
	iss := checkScheduleStatus()
	if !iss.fixable {
		t.Error("schedule check should be fixable")
	}
}

// TestCheckNetwork_notFixable network check is NOT fixable.
func TestCheckNetwork_notFixable(t *testing.T) {
	iss := checkNetwork()
	if iss.fixable {
		t.Error("network check should NOT be fixable")
	}
}

// TestCheckDataDirs_notFixable data dirs check is NOT fixable.
func TestCheckDataDirs_notFixable(t *testing.T) {
	iss := checkDataDirs()
	if iss.fixable {
		t.Error("data dirs check should NOT be fixable")
	}
}

// TestCheckHistoryErrors_notFixable history errors check is NOT fixable.
func TestCheckHistoryErrors_notFixable(t *testing.T) {
	iss := checkHistoryErrors()
	if iss.fixable {
		t.Error("history errors check should NOT be fixable")
	}
}

// TestPrintHealthResults_outputFormat verifies printHealthResults output format.
func TestPrintHealthResults_outputFormat(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	issues := []healthIssue{
		{Name: "test-ok", Status: "ok", Detail: "ready"},
		{Name: "test-fail", Status: "fail", Detail: "missing", Fix: "run fix"},
	}
	printHealthResults(issues)
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	s := string(out)
	if !strings.Contains(s, "\u2713") { // ✓
		t.Errorf("ok items should show checkmark, got:\n%s", s)
	}
	if !strings.Contains(s, "\u2717") { // ✗
		t.Errorf("fail items should show X mark, got:\n%s", s)
	}
	if !strings.Contains(s, "\u4fee\u590d\u5efa\u8bae") { // 修复建议
		t.Errorf("fail items should show fix suggestion, got:\n%s", s)
	}
}

// TestRunHealthCheck_nonInteractive non-interactive runHealthCheck does not block.
func TestRunHealthCheck_nonInteractive(t *testing.T) {
	if err := runHealthCheck(); err != nil {
		t.Fatalf("non-interactive runHealthCheck should return nil, got=%v", err)
	}
}

// TestRunHealthCheck_interactive_allOk all healthy items -> skip fix prompt.
// Note: schedule check always fails in test environment (no system daemon),
// so we provide mock input "3" to select "不修复".
func TestRunHealthCheck_interactive_allOk(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("3\n"))
	defer prompt.SetInput(nil)
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	for _, f := range []string{"global.json", "cf-dns.json", "dnspod.json"} {
		if err := os.WriteFile(filepath.Join(tmp, f), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	cfstDir := filepath.Join(tmp, "assets", "cfst")
	os.MkdirAll(cfstDir, 0o755)
	os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755)

	if err := runHealthCheck(); err != nil {
		t.Fatalf("all ok runHealthCheck should return nil, got=%v", err)
	}
}

// TestRunHealthCheck_interactive_skipFix interactive with issues, user skips fix.
func TestRunHealthCheck_interactive_skipFix(t *testing.T) {
	prompt.SetInteractiveFunc(func() bool { return true })
	defer prompt.SetInteractiveFunc(nil)
	prompt.SetInput(strings.NewReader("3\n"))
	defer prompt.SetInput(nil)

	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	if err := runHealthCheck(); err != nil {
		t.Fatalf("runHealthCheck should return nil, got=%v", err)
	}
}

// TestHealthIssue_fields verifies healthIssue struct fields.
func TestHealthIssue_fields(t *testing.T) {
	iss := healthIssue{
		Name:    "test",
		Status:  "fail",
		Detail:  "broken",
		Fix:     "please fix",
		fixable: true,
	}
	if iss.Name != "test" || iss.Status != "fail" || iss.Detail != "broken" || iss.Fix != "please fix" || !iss.fixable {
		t.Fatal("healthIssue struct fields not correct")
	}
}

// TestDoFix_cfst doFix on cfst (idx=0) should not panic.
// Note: doFix downloads cfst to exe-dir/assets/cfst/ which would pollute
// subsequent tests (cfstBinaryExists finds it). Clean up after test.
func TestDoFix_cfst(t *testing.T) {
	issues := []healthIssue{
		{Name: "cfst", Status: "fail", fixable: true},
		{Name: "config", Status: "fail", fixable: true},
		{Name: "data", Status: "ok"},
		{Name: "network", Status: "ok"},
		{Name: "schedule", Status: "fail", fixable: true},
		{Name: "history", Status: "ok"},
	}
	_ = doFix(issues, 0)
	// Clean up cfst binary downloaded to exe-dir/assets/cfst/ to avoid
	// interfering with cfstBinaryExists() in subsequent tests.
	if exe, err := os.Executable(); err == nil {
		_ = os.RemoveAll(filepath.Join(filepath.Dir(exe), "assets"))
	}
}

// TestDoFix_config doFix on config (idx=1) should generate config files.
func TestDoFix_config(t *testing.T) {
	tmp := t.TempDir()
	origCfgDir := cfgDir
	cfgDir = tmp
	defer func() { cfgDir = origCfgDir }()

	issues := []healthIssue{
		{Name: "cfst", Status: "ok"},
		{Name: "config", Status: "fail", fixable: true},
		{Name: "data", Status: "ok"},
		{Name: "network", Status: "ok"},
		{Name: "schedule", Status: "ok"},
		{Name: "history", Status: "ok"},
	}

	result := doFix(issues, 1)
	if !result {
		t.Fatal("config fix should succeed")
	}
	if issues[1].Status != "ok" {
		t.Fatal("after fix config status should be ok")
	}
	for _, f := range []string{"global.json"} {
		if _, err := os.Stat(filepath.Join(tmp, f)); os.IsNotExist(err) {
			t.Errorf("after fix should generate %s", f)
		}
	}
}

// TestDoFix_schedule_failsInTest doFix on schedule (idx=4) should not panic.
func TestDoFix_schedule_failsInTest(t *testing.T) {
	issues := []healthIssue{
		{Name: "cfst", Status: "ok"},
		{Name: "config", Status: "ok"},
		{Name: "data", Status: "ok"},
		{Name: "network", Status: "ok"},
		{Name: "schedule", Status: "fail", fixable: true},
		{Name: "history", Status: "ok"},
	}
	result := doFix(issues, 4)
	_ = result
}

// TestDoFix_schedule_threeStepStrategy 验证 doFix(idx=4) 的三步策略：
// 1) 先试 start → 2) 试 install+start → 3) 全失败后引导备选调度。
func TestDoFix_schedule_threeStepStrategy(t *testing.T) {
	issues := []healthIssue{
		{Name: "cfst", Status: "ok"},
		{Name: "config", Status: "ok"},
		{Name: "data", Status: "ok"},
		{Name: "network", Status: "ok"},
		{Name: "schedule", Status: "fail", fixable: true},
		{Name: "history", Status: "ok"},
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	result := doFix(issues, 4)

	_ = w.Close()
	os.Stdout = old

	// 测试环境下无系统服务，应返回 false
	if result {
		t.Log("doFix schedule 返回 true（可能系统中有调度服务，跳过断言）")
	} else {
		out, _ := io.ReadAll(r)
		s := string(out)
		// 应打印备选调度提示
		if runtime.GOOS == "windows" {
			if !strings.Contains(s, "schtasks") {
				t.Errorf("Windows 上应引导 schtasks 备选，实际输出:\n%s", s)
			}
			if !strings.Contains(s, "schedule install-schtasks") {
				t.Errorf("应提示 schedule install-schtasks 命令，实际输出:\n%s", s)
			}
		} else {
			if !strings.Contains(s, "crontab") {
				t.Errorf("非 Windows 上应引导 crontab 备选，实际输出:\n%s", s)
			}
			if !strings.Contains(s, "schedule install-cron") {
				t.Errorf("应提示 schedule install-cron 命令，实际输出:\n%s", s)
			}
		}
		// 修复失败不应修改 status
		if issues[4].Status != "fail" {
			t.Error("修复失败后 issues[4].Status 应保持 fail")
		}
	}
}

// TestDoFix_unknownIdx doFix on unknown idx returns false.
func TestDoFix_unknownIdx(t *testing.T) {
	issues := make([]healthIssue, 6)
	for i := range issues {
		issues[i] = healthIssue{Status: "fail"}
	}
	if doFix(issues, 99) {
		t.Error("unknown idx should return false")
	}
	if doFix(issues, -1) {
		t.Error("negative idx should return false")
	}
}

// TestHealthIssue_fixableFlags verifies fixable flags for each check.
func TestHealthIssue_fixableFlags(t *testing.T) {
	issues := runAllChecks()
	fixableExpected := []bool{true, true, false, false, true, false}
	for i, expected := range fixableExpected {
		if issues[i].fixable != expected {
			t.Errorf("issues[%d] (%s).fixable = %v, want %v", i, issues[i].Name, issues[i].fixable, expected)
		}
	}
}

// TestPrintHealthResults_noFixForOK ok items should not print fix suggestion.
func TestPrintHealthResults_noFixForOK(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	issues := []healthIssue{
		{Name: "test", Status: "ok", Detail: "ok", Fix: "should-not-appear"},
	}
	printHealthResults(issues)
	_ = w.Close()
	os.Stdout = old

	out, _ := io.ReadAll(r)
	if bytes.Contains(out, []byte("should-not-appear")) {
		t.Error("ok items should not print fix suggestion")
	}
}

// TestAutoFix_noFixable no fixable items -> 0.
func TestAutoFix_noFixable(t *testing.T) {
	issues := []healthIssue{
		{Name: "a", Status: "fail", fixable: false},
		{Name: "b", Status: "ok", fixable: false},
	}
	fixed, err := autoFix([]healthIssue{}, []int{}, issues)
	if err != nil {
		t.Fatalf("autoFix should return nil err, got=%v", err)
	}
	if fixed != 0 {
		t.Fatalf("no fixable items should return 0, got=%d", fixed)
	}
}
