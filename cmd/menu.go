package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"cfopt/internal/prompt"
)

// crontabExists 检测系统是否安装了 crontab 命令。
func crontabExists() bool {
	_, err := exec.LookPath("crontab")
	return err == nil
}

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

	// 1) CF DNS：检查 conf/cf-dns/ 下是否有 .conf 或 .json
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

// showScheduleCommandLine 输出一行自定义调度命令（供面板 / crontab / 脚本调用）。
func showScheduleCommandLine() error {
	exe, err := os.Executable()
	if err != nil {
		fmt.Println("无法获取当前二进制路径，请手动输入完整路径。")
		return nil
	}
	workDir := filepath.Dir(exe)
	cmd := fmt.Sprintf("cd %s && %s schedule run --once", workDir, exe)

	fmt.Println()
	fmt.Println("=== 自定义调度命令 ===")
	fmt.Println()
	fmt.Println("操作说明：")
	fmt.Println("  1. 在面板/定时任务系统中选择【Shell 脚本】或【自定义命令】")
	fmt.Println("  2. 设置好执行周期（如每天 3:00、每 6 小时等）")
	fmt.Println("  3. 将下方「命令内容」复制粘贴到输入框中")
	fmt.Println()
	fmt.Println("--- 命令内容（直接复制整行）---")
	fmt.Println(cmd)
	fmt.Println("--------------------------------")
	fmt.Println()
	fmt.Printf("提示：请确保执行用户有权限访问 %s 目录。\n", workDir)
	fmt.Println("  该命令单次执行同步后即退出，适合各类面板/定时器调用。")
	if os.Geteuid() == 0 {
		fmt.Println("  ⚠ 当前为 root 用户，面板任务中请勿勾选「需要 sudo」选项，否则会因找不到 sudo 命令而失败。")
	}
	return nil
}

// runScheduleCenter 调度中心子菜单（包装 cfopt schedule install/start/stop/status/uninstall）。
func runScheduleCenter() error {
	if !prompt.IsInteractive() {
		fmt.Println("调度中心为交互式子菜单，当前非交互终端。可直接使用 `cfopt schedule` 子命令。")
		return nil
	}

	items := []prompt.MenuItem{
		{
			Label: "安装并启动调度（systemd / 系统服务，推荐）",
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

	// 输出自定义调度命令（平台无关，始终可用）
	items = append(items, prompt.MenuItem{
		Label: "输出自定义调度命令（供面板/crontab/手动调用）",
		Run:   showScheduleCommandLine,
	})

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
		// Linux/macOS: 动态检测 crontab，不可用时跳过安装选项并提示
		if crontabExists() {
			items = append(items,
				prompt.MenuItem{
					Label: "安装 crontab 调度（无 systemd / 容器环境备选）",
					Run:   func() error { return installCronSchedule("", "") },
				},
				prompt.MenuItem{
					Label: "卸载 crontab 调度",
					Run:   func() error { return uninstallCronSchedule() },
				},
			)
		} else {
			fmt.Println("⚠ 未检测到 crontab。如需 crontab 方式调度，请先安装：")
			fmt.Println("  Debian/Ubuntu:  apt install cron")
			fmt.Println("  CentOS/RHEL:    yum install cronie")
			fmt.Println("  Alpine:         apk add dcron")
			fmt.Println("也可使用上方的「输出自定义调度命令」配合面板定时任务使用。")
			fmt.Println()
		}
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
	var crontabItems []prompt.MenuItem

	if runtime.GOOS == "windows" {
		crontabItems = []prompt.MenuItem{
			{
				Label: "安装 Windows 计划任务（schtasks）",
				Run:   func() error { return installSchtasks("", "") },
			},
			{
				Label: "卸载 Windows 计划任务",
				Run:   func() error { return uninstallSchtasks() },
			},
		}
	} else if crontabExists() {
		crontabItems = []prompt.MenuItem{
			{
				Label: "安装 crontab 备选调度（无 systemd / 容器环境适用）",
				Run:   func() error { return installCronSchedule("", "") },
			},
			{
				Label: "卸载 crontab 调度",
				Run:   func() error { return uninstallCronSchedule() },
			},
		}
	} else {
		// crontab 不可用：打印一次提示，不添加安装选项
		fmt.Println("⚠ 未检测到 crontab。如需 crontab 方式调度，请先安装：")
		fmt.Println("  Debian/Ubuntu:  apt install cron")
		fmt.Println("  CentOS/RHEL:    yum install cronie")
		fmt.Println("  Alpine:         apk add dcron")
		fmt.Println("也可使用下方的「输出自定义调度命令」配合面板定时任务使用。")
		fmt.Println()
	}

	// 进入子菜单前先打印当前调度服务的真实状态，让用户清楚现在是谁在负责定时同步。
	printScheduleStatusBanner()

	return prompt.MenuLoop("同步与调度", append([]prompt.MenuItem{
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
			Label: "安装并启动调度（systemd / 系统服务，推荐）",
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
			Label: "输出自定义调度命令（供面板/crontab/手动调用）",
			Run:   showScheduleCommandLine,
		},
	}, crontabItems...))
}

// printScheduleStatusBanner 在进入「同步与调度」子菜单前打印当前调度服务的真实状态，
// 让用户一目了然：systemd 服务是否运行、crontab/schtasks 备选是否安装（当前由谁负责定时同步）。
func printScheduleStatusBanner() {
	fmt.Println("── 当前调度状态 ──")
	if s := SystemdServiceStatus(); s != "" {
		fmt.Printf("  cfopt 系统服务(systemd): %s\n", s)
	}
	if runtime.GOOS == "windows" {
		if checkSchtasksExists() {
			fmt.Println("  Windows 计划任务: 已安装")
		} else {
			fmt.Println("  Windows 计划任务: 未安装")
		}
	} else {
		if checkCrontabExists() {
			fmt.Println("  crontab 备选调度: 已安装（当前由它负责定时同步）")
		} else {
			fmt.Println("  crontab 备选调度: 未安装")
		}
	}
	fmt.Println()
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
