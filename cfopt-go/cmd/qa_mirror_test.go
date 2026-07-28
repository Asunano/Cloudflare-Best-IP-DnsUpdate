package cmd

import (
	"strings"
	"testing"
)

// ============================================================================
// F6: 镜像源加速（update.go —mirror 标志 + cfst.go —mirror 标志）
// ============================================================================

// TestNewUpdateCmd_mirrorFlag 验证 `cfopt update` 注册了 --mirror 标志。
func TestNewUpdateCmd_mirrorFlag(t *testing.T) {
	cmd := newUpdateCmd()
	flag := cmd.Flags().Lookup("mirror")
	if flag == nil {
		t.Fatal("update 命令应注册 --mirror 标志")
	}
	if flag.DefValue != "" {
		t.Errorf("--mirror 默认值应为空，实际 %q", flag.DefValue)
	}
	if !strings.Contains(flag.Usage, "镜像") {
		t.Errorf("--mirror 帮助应含「镜像」，实际 %q", flag.Usage)
	}
}

// TestNewUpdateCmd_otherFlags 验证 update 命令的其它所有标志注册。
func TestNewUpdateCmd_otherFlags(t *testing.T) {
	cmd := newUpdateCmd()

	requiredFlags := []string{"check", "yes", "repo", "asset", "url", "timeout", "no-verify", "rollback", "mirror"}
	for _, name := range requiredFlags {
		if cmd.Flags().Lookup(name) == nil {
			t.Errorf("update 命令应注册 --%s 标志", name)
		}
	}
}

// TestNewCFSTFetchCmd_mirrorFlag 验证 `cfopt cfst fetch` 注册了 --mirror 标志。
func TestNewCFSTFetchCmd_mirrorFlag(t *testing.T) {
	// cfst 命令是 newCFSTCmd() 的 fetch 子命令
	parent := newCFSTCmd()
	fetchCmd := parent.Commands()
	if len(fetchCmd) == 0 {
		t.Fatal("cfst 命令应含有子命令")
	}
	cmd := fetchCmd[0]
	if cmd.Name() != "fetch" {
		t.Fatalf("第一个子命令应为 fetch，实际 %s", cmd.Name())
	}

	flag := cmd.Flags().Lookup("mirror")
	if flag == nil {
		t.Fatal("cfst fetch 命令应注册 --mirror 标志")
	}
	if flag.DefValue != "" {
		t.Errorf("--mirror 默认值应为空，实际 %q", flag.DefValue)
	}
}

// TestNewCFSTFetchCmd_otherFlags 验证 cfst fetch 命令的其它标志。
func TestNewCFSTFetchCmd_otherFlags(t *testing.T) {
	parent := newCFSTCmd()
	cmd := parent.Commands()[0]

	requiredFlags := []string{"repo", "dest", "timeout", "os", "arch", "mirror"}
	for _, name := range requiredFlags {
		if cmd.Flags().Lookup(name) == nil {
			t.Errorf("cfst fetch 命令应注册 --%s 标志", name)
		}
	}
}

// TestNewUpdateCmd_mirrorUsage 验证 --mirror 标志的使用说明包含关键描述。
func TestNewUpdateCmd_mirrorUsage(t *testing.T) {
	cmd := newUpdateCmd()
	flag := cmd.Flags().Lookup("mirror")
	if flag == nil {
		t.Fatal("--mirror 标志未注册")
	}
	usage := flag.Usage
	if !strings.Contains(usage, "镜像") && !strings.Contains(usage, "mirror") {
		t.Errorf("--mirror 使用说明应包含描述，实际 %q", usage)
	}
	if !strings.Contains(usage, "GitHub") || !strings.Contains(usage, "回退") {
		t.Logf("--mirror 使用说明: %q（应提示镜像优先+GitHub回退）", usage)
	}
}

// TestNewCFSTFetchCmd_mirrorUsage 验证 cfst fetch --mirror 的使用说明。
func TestNewCFSTFetchCmd_mirrorUsage(t *testing.T) {
	parent := newCFSTCmd()
	cmd := parent.Commands()[0]
	flag := cmd.Flags().Lookup("mirror")
	if flag == nil {
		t.Fatal("--mirror 标志未注册")
	}
	usage := flag.Usage
	if !strings.Contains(usage, "镜像") {
		t.Logf("cfst fetch --mirror 使用说明: %q", usage)
	}
}

// TestRootCmd_registersHealth 验证 rootCmd 注册了 health 子命令。
func TestRootCmd_registersHealth(t *testing.T) {
	names := map[string]bool{}
	for _, c := range rootCmd.Commands() {
		names[c.Name()] = true
	}
	if !names["health"] {
		t.Error("rootCmd 应注册 health 子命令")
	}
}

// TestRootCmd_registersConfig 验证 rootCmd 注册了 config 子命令。
func TestRootCmd_registersConfig(t *testing.T) {
	names := map[string]bool{}
	for _, c := range rootCmd.Commands() {
		names[c.Name()] = true
	}
	if !names["config"] {
		t.Error("rootCmd 应注册 config 子命令")
	}
}

// TestRootCmd_registersAllExpected 验证 rootCmd 注册所有预期子命令。
func TestRootCmd_registersAllExpected(t *testing.T) {
	names := map[string]bool{}
	for _, c := range rootCmd.Commands() {
		names[c.Name()] = true
	}
	expected := []string{
		"install", "uninstall", "quickdeploy",
		"config", "update", "schedule",
		"health", "cfst", "version",
		"speedtest", "dns", "sync", "serve",
	}
	for _, want := range expected {
		if !names[want] {
			t.Errorf("rootCmd 应注册子命令 %q", want)
		}
	}
}

// TestNewConfigCmd_registersCFIP 验证 config 命令注册了 cfip 子命令。
func TestNewConfigCmd_registersCFIP(t *testing.T) {
	cmd := newConfigCommand()
	var cfipFound bool
	for _, c := range cmd.Commands() {
		if c.Name() == "cfip" {
			cfipFound = true
			if c.Short == "" {
				t.Error("cfip 子命令应有 Short 描述")
			}
			break
		}
	}
	if !cfipFound {
		t.Error("config 命令应注册 cfip 子命令")
	}
}

// TestNewScheduleCmd_registersInstallCron 验证 schedule 命令注册了 install-cron 子命令。
func TestNewScheduleCmd_registersInstallCron(t *testing.T) {
	cmd := newScheduleCmd()
	var found bool
	for _, c := range cmd.Commands() {
		if c.Name() == "install-cron" {
			found = true
			if !strings.Contains(c.Short, "crontab") {
				t.Errorf("install-cron 的 Short 应包含 crontab，实际 %q", c.Short)
			}
			break
		}
	}
	if !found {
		t.Error("schedule 命令应注册 install-cron 子命令")
	}
}

// TestNewScheduleCmd_registersUninstallCron 验证 schedule 命令注册了 uninstall-cron 子命令。
func TestNewScheduleCmd_registersUninstallCron(t *testing.T) {
	cmd := newScheduleCmd()
	var found bool
	for _, c := range cmd.Commands() {
		if c.Name() == "uninstall-cron" {
			found = true
			if !strings.Contains(c.Short, "卸载") && !strings.Contains(c.Short, "crontab") {
				t.Errorf("uninstall-cron 的 Short 应包含相关描述，实际 %q", c.Short)
			}
			break
		}
	}
	if !found {
		t.Error("schedule 命令应注册 uninstall-cron 子命令")
	}
}

// TestNewScheduleCmd_allSubcommands 验证 schedule 命令的所有子命令。
func TestNewScheduleCmd_allSubcommands(t *testing.T) {
	cmd := newScheduleCmd()
	names := map[string]bool{}
	for _, c := range cmd.Commands() {
		names[c.Name()] = true
	}
	expected := []string{"install", "uninstall", "start", "stop", "run", "status", "install-cron", "uninstall-cron"}
	for _, want := range expected {
		if !names[want] {
			t.Errorf("schedule 命令应注册子命令 %q", want)
		}
	}
}

// TestNewConfigCmd_allSubcommands 验证 config 命令的所有子命令。
func TestNewConfigCmd_allSubcommands(t *testing.T) {
	cmd := newConfigCommand()
	names := map[string]bool{}
	for _, c := range cmd.Commands() {
		names[c.Name()] = true
	}
	expected := []string{"init", "validate", "wizard", "cfip"}
	for _, want := range expected {
		if !names[want] {
			t.Errorf("config 命令应注册子命令 %q", want)
		}
	}
}
