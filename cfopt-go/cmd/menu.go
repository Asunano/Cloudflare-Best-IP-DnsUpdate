package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"cfopt/internal/prompt"
)

// isDomainConfName 判断文件名是否为域名级配置文件（.conf 或 .json，Bash 版遗留用 .json）。
func isDomainConfName(name string) bool {
	return strings.HasSuffix(name, ".conf") || strings.HasSuffix(name, ".json")
}

// runMenu 主菜单循环（无参运行 cfopt 即进入）。非交互终端打印用法即退出，不阻塞。
func runMenu() error {
	// Windows 下推荐优先使用 GUI（纯 CLI 提示，不改 IPC/GUI 契约）。
	if runtime.GOOS == "windows" {
		printWindowsGuiHint()
	}
	if !prompt.IsInteractive() {
		printMenuUsage()
		return nil
	}

	// 系统状态栏
	statusLine := buildStatusLine()
	if statusLine != "" {
		fmt.Println(statusLine)
		fmt.Println()
	}

	return prompt.MenuLoop(fmt.Sprintf("cfopt 主菜单 (v%s)", Version), []prompt.MenuItem{
		{
			Label: "快速部署（Cloudflare/DNSPod 单域名向导）",
			Run:   func() error { return runQuickdeploy(true) },
		},
		{
			Label: "系统健康检测",
			Run:   runHealthCheck,
		},
		{
			Label: "查看已配置域名",
			Run:   runListConfigs,
		},
		{
			Label: "同步与调度",
			Run:   runSyncAndSchedule,
		},
		{
			Label: "检查更新",
			Run:   runCheckUpdate,
		},
		{
			Label: "卸载 cfopt",
			Run:   runUninstall,
		},
	})
}

// buildStatusLine 构建系统状态栏字符串。
// 扫描 CF-IP / CF DNS / DNSPod / cfst 四模块状态。
// 仅在有异常项时打印（各项均正常时返回空字符串）。
func buildStatusLine() string {
	var parts []string

	// 1) CF-IP 配置：检查 cf-ip.json 是否存在
	cfIPPath := filepath.Join(cfgDir, "cf-ip.json")
	if _, err := os.Stat(cfIPPath); err == nil {
		parts = append(parts, "✓ CF-IP")
	} else {
		parts = append(parts, "✗ CF-IP")
	}

	// 2) CF DNS：检查 conf/cf-dns/ 下是否有 .conf 或 .json
	hasCFDNS := false
	if entries, err := os.ReadDir(filepath.Join(cfgDir, "cf-dns")); err == nil {
		for _, e := range entries {
			if !e.IsDir() && isDomainConfName(e.Name()) {
				hasCFDNS = true
				break
			}
		}
	}
	if hasCFDNS {
		parts = append(parts, "✓ CF DNS")
	} else {
		parts = append(parts, "✗ CF DNS")
	}

	// 3) DNSPod：检查 conf/dnspod/ 下是否有 .conf 或 .json
	hasDNSPod := false
	if entries, err := os.ReadDir(filepath.Join(cfgDir, "dnspod")); err == nil {
		for _, e := range entries {
			if !e.IsDir() && isDomainConfName(e.Name()) {
				hasDNSPod = true
				break
			}
		}
	}
	if hasDNSPod {
		parts = append(parts, "✓ DNSPod")
	} else {
		parts = append(parts, "✗ DNSPod")
	}

	// 4) cfst：cfstBinaryExists()
	if cfstBinaryExists() {
		parts = append(parts, "✓ cfst")
	} else {
		parts = append(parts, "✗ cfst")
	}

	// 检查是否有任何异常
	hasError := false
	for _, p := range parts {
		if strings.HasPrefix(p, "✗") {
			hasError = true
			break
		}
	}
	if !hasError {
		return "" // 各项均正常，不打印状态栏
	}

	return "[系统状态] " + strings.Join(parts, " | ")
}

// runScheduleCenter 调度中心子菜单（包装 cfopt schedule install/start/stop/status/uninstall）。
func runScheduleCenter() error {
	if !prompt.IsInteractive() {
		fmt.Println("调度中心为交互式子菜单，当前非交互终端。可直接使用 `cfopt schedule` 子命令。")
		return nil
	}

	items := []prompt.MenuItem{
		{
			Label: "安装并启动调度（默认每 6 小时）",
			Run: func() error {
				if err := runSchedule("install"); err != nil {
					return err
				}
				return runSchedule("start")
			},
		},
		{
			Label: "停止调度",
			Run:   func() error { return runSchedule("stop") },
		},
		{
			Label: "查看调度状态",
			Run:   func() error { return runScheduleStatus() },
		},
		{
			Label: "卸载调度",
			Run:   func() error { return runSchedule("uninstall") },
		},
	}

	// 按平台显示不同的备选调度选项
	if runtime.GOOS == "windows" {
		items = append(items,
			prompt.MenuItem{
				Label: "安装 Windows 计划任务（schtasks）【仅 Windows】",
				Run:   func() error { return installSchtasks("", "") },
			},
			prompt.MenuItem{
				Label: "卸载 Windows 计划任务",
				Run:   func() error { return uninstallSchtasks() },
			},
		)
	} else {
		items = append(items,
			prompt.MenuItem{
				Label: "安装 crontab 调度（备选，适配无系统服务环境）",
				Run:   func() error { return installCronSchedule("", "") },
			},
			prompt.MenuItem{
				Label: "卸载 crontab 调度",
				Run:   func() error { return uninstallCronSchedule() },
			},
		)
	}

	return prompt.MenuLoop("调度中心", items)
}

// runSyncAndSchedule 同步与调度子菜单（合并「立即同步」和「调度中心」）。
func runSyncAndSchedule() error {
	if !prompt.IsInteractive() {
		fmt.Println("同步与调度为交互式子菜单，当前非交互终端。可直接使用 `cfopt sync` 或 `cfopt schedule` 子命令。")
		return nil
	}

	// 构建备选调度选项
	var backupLabel string
	var backupRun func() error
	var backupUninstallLabel string
	var backupUninstallRun func() error

	if runtime.GOOS == "windows" {
		backupLabel = "安装 Windows 计划任务（schtasks）"
		backupRun = func() error { return installSchtasks("", "") }
		backupUninstallLabel = "卸载 Windows 计划任务"
		backupUninstallRun = func() error { return uninstallSchtasks() }
	} else {
		backupLabel = "安装 crontab 备选调度"
		backupRun = func() error { return installCronSchedule("", "") }
		backupUninstallLabel = "卸载 crontab 调度"
		backupUninstallRun = func() error { return uninstallCronSchedule() }
	}

	return prompt.MenuLoop("同步与调度", []prompt.MenuItem{
		{
			Label: "全部同步（测速 → 最优 IP → 更新所有 DNS）",
			Run:   runSyncAll,
		},
		{
			Label: "单域名同步",
			Run:   runSyncSingleSelect,
		},
		{
			Label: "调度状态",
			Run:   func() error { return runScheduleStatus() },
		},
		{
			Label: "安装并启动调度（默认每 6 小时）",
			Run: func() error {
				if err := runSchedule("install"); err != nil {
					return err
				}
				return runSchedule("start")
			},
		},
		{
			Label: "停止调度",
			Run:   func() error { return runSchedule("stop") },
		},
		{
			Label: "卸载调度",
			Run:   func() error { return runSchedule("uninstall") },
		},
		{
			Label: backupLabel,
			Run:   backupRun,
		},
		{
			Label: backupUninstallLabel,
			Run:   backupUninstallRun,
		},
	})
}

// runSyncSingleSelect 列出已配置域名，让用户选择后执行单域名同步。
func runSyncSingleSelect() error {
	type providerInfo struct {
		label string
		dir   string
		modID string // 模块 ID（"cf" 或 "dnspod"）
	}
	providers := []providerInfo{
		{"Cloudflare", filepath.Join(cfgDir, "cf-dns"), "cf"},
		{"DNSPod", filepath.Join(cfgDir, "dnspod"), "dnspod"},
	}

	type domainOption struct {
		provider string
		domain   string
		modID    string
	}
	var options []domainOption

	for _, p := range providers {
		entries, err := os.ReadDir(p.dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			fmt.Fprintf(os.Stderr, "警告：无法读取 %s: %v\n", p.dir, err)
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !isDomainConfName(e.Name()) {
				continue
			}
			domain := strings.TrimSuffix(strings.TrimSuffix(e.Name(), ".conf"), ".json")
			options = append(options, domainOption{
				provider: p.label,
				domain:   domain,
				modID:    p.modID,
			})
		}
	}

	if len(options) == 0 {
		fmt.Println("（未配置任何域名）")
		fmt.Println("请使用「快速部署」添加域名。")
		return nil
	}

	selected, err := prompt.AskChoice("选择要同步的域名", options,
		func(o domainOption) string { return o.provider + " " + o.domain })
	if err != nil {
		return nil // 用户取消
	}

	return runSyncSingle(selected.modID, selected.domain)
}

// printMenuUsage 非交互终端下打印主菜单与用法，避免卡死。
func printMenuUsage() {
	fmt.Println("cfopt 主菜单（非交互模式，请使用具体子命令）：")
	fmt.Println("  1) 快速部署 : cfopt quickdeploy")
	fmt.Println("  2) 系统健康检测 : cfopt health")
	fmt.Println("  3) 查看已配置域名 : cfopt list")
	fmt.Println("  4) 同步与调度 : cfopt sync / cfopt schedule [install|start|stop|status|uninstall|install-cron|uninstall-cron]")
	fmt.Println("  5) 检查更新 : cfopt update --check")
	fmt.Println("  6) 卸载 : cfopt uninstall")
	fmt.Println("  0) 退出")
	fmt.Println()
	fmt.Println("更完整的帮助：cfopt --help")
}
