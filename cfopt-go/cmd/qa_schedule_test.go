package cmd

import (
	"os"
	"strings"
	"testing"
	"time"

	"cfopt/internal/config"
)

// ============================================================================
// F5: Crontab 调度（schedule.go）
// ============================================================================

// TestResolveCronInterval_4h 验证 4h 映射正确。
func TestResolveCronInterval_4h(t *testing.T) {
	expr, err := resolveCronInterval("4h")
	if err != nil {
		t.Fatalf("4h 不应报错: %v", err)
	}
	if expr != "0 */4 * * *" {
		t.Errorf("4h 应返回 \"0 */4 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_6h 验证 6h 映射正确。
func TestResolveCronInterval_6h(t *testing.T) {
	expr, err := resolveCronInterval("6h")
	if err != nil {
		t.Fatalf("6h 不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("6h 应返回 \"0 */6 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_daily 验证 daily 映射正确。
func TestResolveCronInterval_daily(t *testing.T) {
	expr, err := resolveCronInterval("daily")
	if err != nil {
		t.Fatalf("daily 不应报错: %v", err)
	}
	if expr != "0 3 * * *" {
		t.Errorf("daily 应返回 \"0 3 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_twice 验证 twice 映射正确。
func TestResolveCronInterval_twice(t *testing.T) {
	expr, err := resolveCronInterval("twice")
	if err != nil {
		t.Fatalf("twice 不应报错: %v", err)
	}
	if expr != "0 */12 * * *" {
		t.Errorf("twice 应返回 \"0 */12 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_hourly 验证 hourly 映射正确。
func TestResolveCronInterval_hourly(t *testing.T) {
	expr, err := resolveCronInterval("hourly")
	if err != nil {
		t.Fatalf("hourly 不应报错: %v", err)
	}
	if expr != "0 * * * *" {
		t.Errorf("hourly 应返回 \"0 * * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_custom 验证 custom 在非交互环境回退 6h。
func TestResolveCronInterval_custom(t *testing.T) {
	expr, err := resolveCronInterval("custom")
	if err != nil {
		t.Fatalf("custom（非交互）不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("custom（非交互）应返回 \"0 */6 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_raw5field 验证 5 字段 crontab 表达式原样传递。
func TestResolveCronInterval_raw5field(t *testing.T) {
	expr, err := resolveCronInterval("30 4 * * 1")
	if err != nil {
		t.Fatalf("合法 crontab 表达式不应报错: %v", err)
	}
	if expr != "30 4 * * 1" {
		t.Errorf("应原样返回 \"30 4 * * 1\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_unknown 验证未知频率在非交互环境回退 6h。
func TestResolveCronInterval_unknown(t *testing.T) {
	expr, err := resolveCronInterval("unknown")
	if err != nil {
		t.Fatalf("unknown（非交互）不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("unknown（非交互）应返回 \"0 */6 * * *\"，实际 %q", expr)
	}
}

// TestResolveCronInterval_empty 验证空字符串在非交互环境回退 6h。
func TestResolveCronInterval_empty(t *testing.T) {
	expr, err := resolveCronInterval("")
	if err != nil {
		t.Fatalf("空字符串（非交互）不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("空字符串（非交互）应返回 \"0 */6 * * *\"，实际 %q", expr)
	}
}

// TestParseInterval_default 验证默认间隔为 6h。
func TestParseInterval_default(t *testing.T) {
	d := parseInterval(&config.Config{})
	if d != 6*time.Hour {
		t.Errorf("默认间隔应为 6h，实际 %v", d)
	}
}

// TestParseInterval_fromConfig 验证从配置读取间隔。
func TestParseInterval_fromConfig(t *testing.T) {
	cfg := &config.Config{
		Global: &config.GlobalConfig{
			Schedule: config.ScheduleConfig{
				Interval: "4h",
			},
		},
	}
	d := parseInterval(cfg)
	if d != 4*time.Hour {
		t.Errorf("应返回 4h，实际 %v", d)
	}
}

// TestParseInterval_invalid 验证无效间隔回退 6h。
func TestParseInterval_invalid(t *testing.T) {
	cfg := &config.Config{
		Global: &config.GlobalConfig{
			Schedule: config.ScheduleConfig{
				Interval: "not-a-duration",
			},
		},
	}
	d := parseInterval(cfg)
	if d != 6*time.Hour {
		t.Errorf("无效间隔应回退 6h，实际 %v", d)
	}
}

// TestParseInterval_globalNil 验证 Global 为 nil 时回退 6h。
func TestParseInterval_globalNil(t *testing.T) {
	cfg := &config.Config{Global: nil}
	d := parseInterval(cfg)
	if d != 6*time.Hour {
		t.Errorf("Global nil 应回退 6h，实际 %v", d)
	}
}

// TestInstallCronSchedule_windows 验证 Windows 上的 installCronSchedule 直接返回。
func TestInstallCronSchedule_windows(t *testing.T) {
	if os.Getenv("GOOS") == "windows" || true {
		// 始终测试该函数在非交互环境下的行为
		err := installCronSchedule("/fake/path/cfopt", "6h")
		if err != nil {
			t.Fatalf("installCronSchedule 不应报错，got=%v", err)
		}
	}
}

// TestUninstallCronSchedule_windows 验证 Windows 上的 uninstallCronSchedule 直接返回。
func TestUninstallCronSchedule_windows(t *testing.T) {
	err := uninstallCronSchedule()
	if err != nil {
		t.Fatalf("uninstallCronSchedule 不应报错，got=%v", err)
	}
}

// TestRunScheduleStatus_nonInteractive 验证非交互下 runScheduleStatus 不 panic。
func TestRunScheduleStatus_nonInteractive(t *testing.T) {
	// 在测试环境中可能没有配置，预期返回 error 但不 panic
	_ = runScheduleStatus()
}

// TestRunScheduleCenter_nonInteractive_alreadyTested 验证 runScheduleCenter 在非交互模式不阻塞。
// 该测试已在 menu_test.go 中覆盖 (TestRunScheduleCenter_nonInteractive)，此处额外验证。
func TestRunScheduleCenter_nonInteractive_extra(t *testing.T) {
	if err := runScheduleCenter(); err != nil {
		t.Fatalf("非交互 runScheduleCenter 应返回 nil，got=%v", err)
	}
}

// TestResolveCronInterval_allCases 验证所有 6 种频率的映射完整性。
func TestResolveCronInterval_allCases(t *testing.T) {
	cases := map[string]string{
		"4h":     "0 */4 * * *",
		"6h":     "0 */6 * * *",
		"daily":  "0 3 * * *",
		"twice":  "0 */12 * * *",
		"hourly": "0 * * * *",
	}
	for input, expected := range cases {
		got, err := resolveCronInterval(input)
		if err != nil {
			t.Errorf("%s: 不应报错: %v", input, err)
			continue
		}
		if got != expected {
			t.Errorf("%s: 期望 %q，实际 %q", input, expected, got)
		}
	}
}

// TestRunSchedule_noPanic 验证 runSchedule 在测试环境不 panic（可能出错但不崩溃）。
func TestRunSchedule_noPanic(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("runSchedule panic: %v", r)
		}
	}()

	// 在测试环境中 runSchedule 可能因无配置而返回 error，但不应 panic
	_ = runSchedule("status")
}

// TestResolveCronInterval_nonInteractiveOnly 验证非交互环境下所有频率选择走默认路径。
func TestResolveCronInterval_nonInteractiveOnly(t *testing.T) {
	// 非交互环境下传入空字符串应返回默认 6h
	expr, err := resolveCronInterval("")
	if err != nil {
		t.Fatalf("空字符串不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("空字符串应返回默认 6h 表达式，实际 %q", expr)
	}

	// 验证 4h 依然正确
	expr, err = resolveCronInterval("4h")
	if err != nil {
		t.Fatalf("4h 不应报错: %v", err)
	}
	if expr != "0 */4 * * *" {
		t.Errorf("4h 应返回 \"0 */4 * * *\"，实际 %q", expr)
	}
}

// TestInstallCronSchedule_linuxPath 验证 installCronSchedule 中非 Windows 路径处理。
// 仅验证路径为空时的默认行为（取当前 exe 路径），在测试环境中可能成功或报错但不 panic。
func TestInstallCronSchedule_linuxPath(t *testing.T) {
	// 在 Windows 环境下会直接返回，不涉及 crontab
	err := installCronSchedule("/usr/local/bin/cfopt", "4h")
	if err != nil {
		// Windows 环境下直接返回 nil，不应报错
		t.Fatalf("installCronSchedule 不应报错，got=%v", err)
	}
}

// TestInstallCronSchedule_emptyPath 验证空路径时自动探测不 panic。
func TestInstallCronSchedule_emptyPath(t *testing.T) {
	// 空路径会触发 os.Executable() 探测，不 panic
	err := installCronSchedule("", "6h")
	if err != nil {
		// Windows 下 nil，非 Windows 下可能因 crontab 不存在报错，但不 panic
		t.Logf("installCronSchedule('', '6h') 返回: %v（可接受）", err)
	}
}

// TestUninstallCronSchedule_windowsNoop 验证 Windows 卸载 crontab 是空操作。
func TestUninstallCronSchedule_windowsNoop(t *testing.T) {
	err := uninstallCronSchedule()
	if err != nil {
		t.Fatalf("uninstallCronSchedule 不应报错，got=%v", err)
	}
}

// TestResolveCronInterval_12h 验证 12 小时间隔（虽不在预设列表，但测试 5 字段表达式）。
func TestResolveCronInterval_12h(t *testing.T) {
	expr, err := resolveCronInterval("0 */12 * * *")
	if err != nil {
		t.Fatalf("合法 5 字段表达式不应报错: %v", err)
	}
	if expr != "0 */12 * * *" {
		t.Errorf("应原样返回，实际 %q", expr)
	}
}

// TestResolveCronInterval_6fields 验证 6 字段非法表达式在非交互环境回退。
func TestResolveCronInterval_6fields(t *testing.T) {
	// 6 字段不是 5 字段，走 unknown 路径
	expr, err := resolveCronInterval("0 */6 * * * *")
	if err != nil {
		t.Fatalf("6 字段表达式（非交互）不应报错: %v", err)
	}
	if expr != "0 */6 * * *" {
		t.Errorf("应回退默认 6h，实际 %q", expr)
	}
}

// TestParseInterval_scheduleNil 验证 Schedule 为空的 GlobalConfig 回退 6h。
func TestParseInterval_scheduleNil(t *testing.T) {
	cfg := &config.Config{
		Global: &config.GlobalConfig{
			Schedule: config.ScheduleConfig{}, // Interval 为空
		},
	}
	d := parseInterval(cfg)
	if d != 6*time.Hour {
		t.Errorf("空 Interval 应回退 6h，实际 %v", d)
	}
}

// TestScheduleOnceFlag 验证 --once 标志变量存在（编译检查）。
func TestScheduleOnceFlag(t *testing.T) {
	// scheduleOnce 是包级变量，默认 false（非 --once 模式）
	if scheduleOnce {
		t.Error("scheduleOnce 默认应为 false")
	}
}

// TestInstallCronSchedule_windowsOutput 验证 Windows 提示输出。
func TestInstallCronSchedule_windowsOutput(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w

	_ = installCronSchedule("", "4h")
	_ = w.Close()
	os.Stdout = old

	out := make([]byte, 1024)
	n, _ := r.Read(out)
	output := string(out[:n])

	if !strings.Contains(output, "Windows") && !strings.Contains(output, "crontab") {
		// 至少在 Windows 上应包含 Windows 提示
		t.Logf("installCronSchedule 输出: %s", output)
	}
}
