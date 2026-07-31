package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/prompt"
	"cfopt/internal/scheduler"
)

// scheduleOnce 标记 --once（单次运行，供 cron 唤醒）。
var scheduleOnce bool

// newScheduleCmd 构造 `cfopt schedule` 命令（含 install/uninstall/start/stop/run 子命令）。
// 无子命令时等同于 `run`（常驻或 --once 单次）。
func newScheduleCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "schedule",
		Short: "启动调度器 / 常驻 daemon（带看门狗超时保护）",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSchedule("run")
		},
	}
	cmd.PersistentFlags().BoolVar(&scheduleOnce, "once", false, "单次运行后退出（供 cron 直接唤醒二进制）")
	cmd.AddCommand(
		&cobra.Command{Use: "install", Short: "注册系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("install") }},
		&cobra.Command{Use: "uninstall", Short: "注销系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("uninstall") }},
		&cobra.Command{Use: "start", Short: "启动系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("start") }},
		&cobra.Command{Use: "stop", Short: "停止系统服务", RunE: func(c *cobra.Command, a []string) error { return runSchedule("stop") }},
		&cobra.Command{Use: "run", Short: "前台运行（常驻或 --once 单次）", RunE: func(c *cobra.Command, a []string) error { return runSchedule("run") }},
		&cobra.Command{Use: "status", Short: "查看服务运行状态与最近历史", RunE: func(c *cobra.Command, a []string) error { return runScheduleStatus() }},
		&cobra.Command{
			Use:   "install-cron",
			Short: "安装 crontab 调度（备选，适配无系统服务环境）",
			Long:  "将 cfopt schedule run --once 注册到系统 crontab，按指定频率执行。仅 Linux 支持。",
			RunE: func(c *cobra.Command, args []string) error {
				freq := ""
				if len(args) > 0 {
					freq = args[0]
				}
				return installCronSchedule("", freq)
			},
		},
		&cobra.Command{
			Use:   "uninstall-cron",
			Short: "卸载 crontab 调度",
			RunE: func(c *cobra.Command, args []string) error {
				return uninstallCronSchedule()
			},
		},
		&cobra.Command{
			Use:   "install-schtasks",
			Short: "安装 Windows 计划任务调度（备选，仅 Windows）",
			Long:  "将 cfopt schedule run --once 注册到 Windows 计划任务，按指定频率执行。仅 Windows 支持。",
			RunE: func(c *cobra.Command, args []string) error {
				freq := ""
				if len(args) > 0 {
					freq = args[0]
				}
				return installSchtasks("", freq)
			},
		},
		&cobra.Command{
			Use:   "uninstall-schtasks",
			Short: "卸载 Windows 计划任务调度",
			RunE: func(c *cobra.Command, args []string) error {
				return uninstallSchtasks()
			},
		},
		panelCronCmd,
	)
	return cmd
}

// showPanelCron 打印宝塔/1Panel 面板可用的调度命令（含操作说明与提示）。
// 频率由面板自身设置，因此只输出脚本命令本身（无 crontab 表达式前缀）。
func showPanelCron(binPath string) error {
	script, err := buildPanelCronScript(binPath)
	if err != nil {
		return err
	}
	fmt.Println("面板调度命令生成器 (宝塔 / 1Panel)")
	fmt.Println()
	fmt.Println("操作说明：")
	fmt.Println("  1. 在面板中选择【计划任务】->【添加任务】->【Shell 脚本】")
	fmt.Println("  2. 设置好执行周期（如每天 3:00）")
	fmt.Println("  3. 将下方「脚本内容」复制粘贴到输入框中")
	fmt.Println()
	fmt.Println("--- 脚本内容 (直接复制整行) ---")
	fmt.Println(script)
	fmt.Println("--------------------------------")
	fmt.Println()
	fmt.Printf("提示：请确保面板执行用户有权限访问 %s 目录。\n", filepath.Dir(binPathOrExec(binPath)))
	if os.Geteuid() == 0 {
		fmt.Println("  ⚠ 当前为 root 用户，面板任务中请勿勾选「需要 sudo」选项，否则会因找不到 sudo 命令而失败。")
	}
	return nil
}

// buildPanelCronScript 依据 cfopt 二进制路径生成面板调度命令。
// 使用绝对路径并先 cd 到工作目录，确保默认 conf 配置被正确加载。
func buildPanelCronScript(binPath string) (string, error) {
	if binPath == "" {
		if exe, err := os.Executable(); err == nil {
			binPath = exe
		} else {
			return "", common.Wrap("panel-cron:exe", fmt.Errorf("无法获取当前二进制路径: %w", err))
		}
	}
	workDir := filepath.Dir(binPath)
	logPath := filepath.Join(workDir, "cfopt-cron.log")
	return fmt.Sprintf("cd %s && %s schedule run --once >> %s 2>&1", workDir, binPath, logPath), nil
}

// binPathOrExec 返回用于提示的目录基准：显式给定就用给定路径，否则回退当前二进制所在目录。
func binPathOrExec(binPath string) string {
	if binPath != "" {
		return binPath
	}
	if exe, err := os.Executable(); err == nil {
		return exe
	}
	return "cfopt"
}

// panelCronCmd 构造 `cfopt schedule panel-cron` 子命令（面板调度命令生成器）。
var panelCronCmd = &cobra.Command{
	Use:   "panel-cron",
	Short: "生成宝塔/1Panel 面板可粘贴的调度命令",
	Long:  "输出一行 Shell 命令，可在宝塔/1Panel 的「计划任务 → Shell 脚本」中直接粘贴使用（面板自身设置执行周期）。",
	RunE: func(c *cobra.Command, args []string) error {
		return showPanelCron(panelCronBin)
	},
}

func init() {
	panelCronCmd.Flags().StringVar(&panelCronBin, "bin", "", "cfopt 二进制路径（默认自动探测）")
}

// panelCronBin 保存 --bin 标志值（供 panel-cron 子命令使用）。
var panelCronBin string

// runScheduleStatus 查询系统服务运行状态，并打印最近历史记录（供运维快速确认）。
func runScheduleStatus() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return err
	}

	// 仅查询服务状态无需构建 Syncer：用 StatusOnly 构造避免触碰 cfst 二进制路径。
	// 查询失败（如容器内无 systemd）不应中断：降级显示 unknown，继续检查 crontab 备选与历史。
	st, stErr := scheduler.NewDaemonStatusOnly().Status()
	if stErr != nil {
		fmt.Println("服务状态: unknown（系统服务不可查询，当前环境可能无 systemd）")
	} else {
		fmt.Printf("服务状态: %s\n", st)
		// systemd 的 activating(auto-restart) 会被上报为 running，需二次甄别崩溃重启循环。
		if st == "running" {
			if loop, detail := detectRestartLoop(); loop {
				fmt.Printf("  ⚠ 服务处于崩溃重启循环（%s）\n", detail)
				fmt.Println("    服务单元可能已损坏或过旧，请重新安装：`cfopt schedule uninstall` → `install` → `start`")
			}
		}
	}
	if runtime.GOOS != "windows" {
		if checkCrontabExists() {
			fmt.Println("crontab 备选调度: 已安装")
		} else if stErr != nil || st != "running" {
			fmt.Println("crontab 备选调度: 未安装（可运行 `cfopt schedule install-cron`）")
		}
	}

	recs, readErr := hist.ReadLatest(5)
	if readErr != nil {
		common.Warn("cmd:schedule:status: 读取历史失败", "err", readErr.Error())
	} else if len(recs) == 0 {
		fmt.Println("最近历史: (无)")
	} else {
		fmt.Println("最近历史:")
		for _, e := range recs {
			fmt.Printf("  %s  %-16s 成功=%v  %s\n",
				e.Timestamp.Format("2006-01-02 15:04:05"), e.Action, e.Success, e.Detail)
		}
	}
	return nil
}

// runSchedule 构建 Scheduler/Daemon 并执行服务动作。
func runSchedule(action string) error {
	// 安装系统服务前置检测：Linux 环境缺少 systemctl 时提早引导用户换用 crontab
	if action == "install" && runtime.GOOS == "linux" {
		if _, err := exec.LookPath("systemctl"); err != nil {
			fmt.Println("⚠ 未检测到 systemctl，当前环境可能不支持 systemd 系统服务。")
			fmt.Println()
			fmt.Println("  替代方案：使用 crontab 调度")
			fmt.Println("    主菜单 → 同步与调度 → 安装 crontab 备选调度")
			fmt.Println("    或运行 `cfopt schedule install-cron`")
			return common.New("schedule", "systemctl 不可用，请改用 crontab 调度")
		}
	}

	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return err
	}
	sched, err := scheduler.NewScheduler(cfg, hist)
	if err != nil {
		return common.Wrap("cmd:schedule:build", err)
	}
	var daemon *scheduler.Daemon
	if action == "install" {
		// 安装时传入配置目录绝对路径：其父目录写入 systemd 单元 WorkingDirectory
		//（./assets/data 等相对路径以其为基准），自身经 --config-dir 写入 ExecStart。
		absDir, _ := filepath.Abs(cfgDir)
		daemon = scheduler.NewDaemonWithConfigDir(sched, cfg, parseInterval(cfg), scheduleOnce, absDir)
	} else {
		daemon = scheduler.NewDaemon(sched, cfg, parseInterval(cfg), scheduleOnce)
	}
	return daemon.RunService(action)
}

// parseInterval 解析调度间隔（global.schedule.interval，Go duration 字符串），默认 6h。
func parseInterval(cfg *config.Config) time.Duration {
	if cfg.Global != nil && cfg.Global.Schedule.Interval != "" {
		if d, err := time.ParseDuration(cfg.Global.Schedule.Interval); err == nil {
			return d
		}
	}
	return 6 * time.Hour
}

// checkCrontabAvailable 检测 crontab 命令是否存在，不存在时给出引导提示。
func checkCrontabAvailable() bool {
	if _, err := exec.LookPath("crontab"); err != nil {
		fmt.Println("⚠ 系统未安装 crontab，无法使用此功能。")
		rootHint := ""
	if os.Geteuid() != 0 {
		rootHint = "（需 root 权限）"
	}
	fmt.Println()
	fmt.Println("  方案一：安装 crontab")
	fmt.Println("    Debian/Ubuntu:  apt install cron")
	fmt.Println("    CentOS/RHEL:    yum install cronie")
	fmt.Println("    Alpine:         apk add dcron")
	fmt.Println()
	fmt.Printf("  方案二：使用 systemd 调度（推荐）%s\n", rootHint)
	fmt.Println("    在主菜单选择「安装并启动调度（默认每 6 小时）」")
	fmt.Println()
	fmt.Println("  方案三：无需常驻，通过宝塔/1Panel 面板添加计划任务")
	fmt.Println("    运行 `cfopt schedule panel-cron` 生成脚本命令")
		return false
	}
	return true
}

// installCronSchedule 安装 crontab 调度（仅 Linux）。
// cfoptPath 为空时自动探测当前二进制路径。
// interval 为空时交互式选择，否则为 "4h"/"6h"/"daily"/"twice"/"hourly"/"custom"。
func installCronSchedule(cfoptPath, interval string) error {
	if runtime.GOOS == "windows" {
		fmt.Println("Windows 环境：建议使用系统服务（`cfopt schedule install`）而非 crontab。")
		fmt.Println("如需使用计划任务，请使用 Windows 任务计划程序手动创建。")
		return nil
	}

	// 非 Linux 提示
	if runtime.GOOS != "linux" {
		fmt.Printf("当前系统 %s：crontab 调度仅 Linux 完全支持。建议使用系统服务。\n", runtime.GOOS)
	}

	// 前置检测：crontab 命令是否存在
	if !checkCrontabAvailable() {
		return nil // 交互提示已由 checkCrontabAvailable 打印
	}

	// 探测 cfopt 路径
	if cfoptPath == "" {
		if exe, err := os.Executable(); err == nil {
			cfoptPath = exe
		} else {
			return common.Wrap("cron:exe", fmt.Errorf("无法获取当前二进制路径: %w", err))
		}
	}

	// 解析或选择频率
	cronExpr, err := resolveCronInterval(interval)
	if err != nil {
		return err
	}

	// 读取当前 crontab
	currentCron, err := exec.Command("crontab", "-l").Output()
	cronContent := ""
	if err == nil {
		cronContent = string(currentCron)
	}

	// 检查是否已安装
	if strings.Contains(cronContent, cfoptPath) && strings.Contains(cronContent, "schedule run --once") {
		fmt.Println("crontab 中已存在 cfopt 调度条目。")
		if prompt.IsInteractive() && !prompt.Confirm("是否重新安装？", false) {
			return nil
		}
		// 先卸载再安装
		if err := uninstallCronSchedule(); err != nil {
			common.Warn("cron: 卸载旧条目失败", "err", err.Error())
		}
		// 重新读取（已清除旧条目）
		currentCron, err = exec.Command("crontab", "-l").Output()
		if err == nil {
			cronContent = string(currentCron)
		} else {
			cronContent = ""
		}
	}

	// 工作目录取 cfopt 所在目录
	workDir := filepath.Dir(cfoptPath)

	// 追加 crontab 条目：cd 到工作目录后执行
	line := fmt.Sprintf("%s cd %s && %s schedule run --once >> cfopt-cron.log 2>&1", cronExpr, workDir, cfoptPath)

	newCron := cronContent
	if !strings.HasSuffix(newCron, "\n") && newCron != "" {
		newCron += "\n"
	}
	newCron += line + "\n"

	// 通过 crontab 命令写入
	cmd := exec.Command("crontab")
	cmd.Stdin = strings.NewReader(newCron)
	if out, err := cmd.CombinedOutput(); err != nil {
		return common.Wrap("cron:install", fmt.Errorf(
			"crontab 写入失败: %w\n输出: %s\n\n提示：可尝试 `crontab -e` 手动添加，或使用 systemd 调度。", err, string(out)))
	}

	fmt.Printf("✓ crontab 调度已安装: %s\n", line)
	fmt.Println("  日志将写入: cfopt-cron.log（在 cfopt 所在目录）")
	return nil
}

// uninstallCronSchedule 卸载 crontab 中所有 cfopt 相关条目。
func uninstallCronSchedule() error {
	if runtime.GOOS == "windows" {
		fmt.Println("Windows 环境无 crontab，请使用 `cfopt schedule uninstall` 卸载调度。")
		return nil
	}

	// 前置检测：crontab 命令是否存在
	if !checkCrontabAvailable() {
		return nil
	}

	// 读取当前 crontab
	currentCron, err := exec.Command("crontab", "-l").Output()
	if err != nil {
		// crontab -l 可能返回非零退出码（无 crontab）
		fmt.Println("当前无 crontab 配置。")
		return nil
	}

	lines := strings.Split(string(currentCron), "\n")
	var newLines []string
	removed := 0
	for _, line := range lines {
		if strings.Contains(line, "schedule run --once") {
			removed++
			continue
		}
		newLines = append(newLines, line)
	}

	if removed == 0 {
		fmt.Println("未找到 cfopt crontab 条目。")
		return nil
	}

	newCron := strings.Join(newLines, "\n")
	newCron = strings.TrimSpace(newCron) + "\n"

	cmd := exec.Command("crontab")
	cmd.Stdin = strings.NewReader(newCron)
	if out, err := cmd.CombinedOutput(); err != nil {
		return common.Wrap("cron:uninstall", fmt.Errorf("crontab 写入失败: %w\n输出: %s", err, string(out)))
	}

	fmt.Printf("✓ 已移除 %d 个 cfopt crontab 条目\n", removed)
	return nil
}

// resolveCronInterval 解析频率字符串为 crontab 表达式。
// 空字符串时交互式选择。
func resolveCronInterval(interval string) (string, error) {
	if interval != "" {
		switch interval {
		case "4h":
			return "0 */4 * * *", nil
		case "6h":
			return "0 */6 * * *", nil
		case "daily":
			return "0 3 * * *", nil
		case "twice":
			return "0 */12 * * *", nil
		case "hourly":
			return "0 * * * *", nil
		case "custom":
			// 需要进一步交互
		default:
			// 检查是否已经是有效的 crontab 表达式（5 字段）
			fields := strings.Fields(interval)
			if len(fields) == 5 {
				return interval, nil
			}
			fmt.Printf("未知频率: %s，将进入交互选择。\n", interval)
		}
	}

	// 交互式选择
	if prompt.IsInteractive() {
		fmt.Println("选择调度频率：")
		freqs := []struct {
			label string
			expr  string
		}{
			{"每 4 小时 (0 */4 * * *)", "0 */4 * * *"},
			{"每 6 小时 (0 */6 * * *)", "0 */6 * * *"},
			{"每天凌晨 3 点 (0 3 * * *)", "0 3 * * *"},
			{"每 12 小时 (0 */12 * * *)", "0 */12 * * *"},
			{"每小时 (0 * * * *)", "0 * * * *"},
			{"自定义表达式", "custom"},
		}
		choice, err := prompt.AskChoice("选择频率", freqs,
			func(f struct {
				label string
				expr  string
			}) string { return f.label })
		if err != nil {
			return "", fmt.Errorf("用户取消选择")
		}
		if choice.expr == "custom" {
			fmt.Print("请输入自定义 crontab 表达式（5 字段，如: 0 */6 * * *）: ")
			custom := prompt.Ask("crontab 表达式", "0 */6 * * *")
			fields := strings.Fields(strings.TrimSpace(custom))
			if len(fields) != 5 {
				return "", fmt.Errorf("无效的 crontab 表达式，需要 5 个字段")
			}
			return custom, nil
		}
		return choice.expr, nil
	}

	// 非交互默认 6h
	return "0 */6 * * *", nil
}

// installSchtasks 安装 Windows 计划任务调度（仅 Windows）。
// cfoptPath 为空时自动探测当前二进制路径。
// interval 为空时交互式选择，否则为 "4h"/"6h"/"daily"/"twice"/"hourly"/"custom"。
func installSchtasks(cfoptPath, interval string) error {
	if runtime.GOOS != "windows" {
		fmt.Println("schtasks 仅支持 Windows 系统。")
		return nil
	}

	// 探测 cfopt 路径
	if cfoptPath == "" {
		if exe, err := os.Executable(); err == nil {
			cfoptPath = exe
		} else {
			return common.Wrap("schtasks:exe", fmt.Errorf("无法获取当前二进制路径: %w", err))
		}
	}

	// 解析或选择频率
	modVal, err := resolveSchtasksInterval(interval)
	if err != nil {
		return err
	}

	taskName := "CFOPT_Sync"
	trArg := fmt.Sprintf(`"%s" schedule run --once`, cfoptPath)

	// 检查是否已存在
	check := exec.Command("schtasks", "/query", "/tn", taskName)
	if err := check.Run(); err == nil {
		fmt.Printf("计划任务 %s 已存在。\n", taskName)
		if prompt.IsInteractive() && !prompt.Confirm("是否重新安装？", false) {
			return nil
		}
		// 先卸载
		if err := uninstallSchtasks(); err != nil {
			common.Warn("schtasks: 卸载旧任务失败", "err", err.Error())
		}
	}

	// 创建计划任务：每 N 小时执行一次，持续时间无限
	// schtasks /create /tn "CFOPT_Sync" /tr "\"cfoptPath\" schedule run --once" /sc hourly /mo N /st 00:00 /du 9999:59 /f
	args := []string{
		"/create",
		"/tn", taskName,
		"/tr", trArg,
		"/sc", "hourly",
		"/mo", modVal,
		"/st", "00:00",
		"/du", "9999:59",
		"/f",
	}

	cmd := exec.Command("schtasks", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return common.Wrap("schtasks:install", fmt.Errorf("计划任务创建失败: %w\n输出: %s", err, string(out)))
	}

	fmt.Printf("✓ Windows 计划任务已安装: %s（每 %s 小时执行一次）\n", taskName, modVal)
	fmt.Printf("  任务命令: %s\n", trArg)
	return nil
}

// uninstallSchtasks 卸载 Windows 计划任务。
func uninstallSchtasks() error {
	if runtime.GOOS != "windows" {
		fmt.Println("schtasks 仅支持 Windows 系统。")
		return nil
	}

	taskName := "CFOPT_Sync"

	// 检查是否存在
	check := exec.Command("schtasks", "/query", "/tn", taskName)
	if err := check.Run(); err != nil {
		fmt.Printf("计划任务 %s 不存在。\n", taskName)
		return nil
	}

	// 删除计划任务
	cmd := exec.Command("schtasks", "/delete", "/tn", taskName, "/f")
	if out, err := cmd.CombinedOutput(); err != nil {
		return common.Wrap("schtasks:uninstall", fmt.Errorf("计划任务删除失败: %w\n输出: %s", err, string(out)))
	}

	fmt.Printf("✓ 已卸载计划任务: %s\n", taskName)
	return nil
}

// resolveSchtasksInterval 解析频率字符串为 schtasks 的 /mo 参数值（小时数）。
// 空字符串时交互式选择。
func resolveSchtasksInterval(interval string) (string, error) {
	if interval != "" {
		switch interval {
		case "4h":
			return "4", nil
		case "6h":
			return "6", nil
		case "daily":
			return "24", nil
		case "twice":
			return "12", nil
		case "hourly":
			return "1", nil
		default:
			// 尝试解析为纯数字（小时数）
			if n, err := strconv.Atoi(interval); err == nil && n > 0 && n <= 999 {
				return fmt.Sprintf("%d", n), nil
			}
			fmt.Printf("未知频率: %s，将进入交互选择。\n", interval)
		}
	}

	// 交互式选择
	if prompt.IsInteractive() {
		fmt.Println("选择调度频率：")
		freqs := []struct {
			label string
			val   string
		}{
			{"每 4 小时", "4"},
			{"每 6 小时", "6"},
			{"每 12 小时", "12"},
			{"每 24 小时（每天）", "24"},
			{"每小时", "1"},
			{"自定义小时数", "custom"},
		}
		choice, err := prompt.AskChoice("选择频率", freqs,
			func(f struct {
				label string
				val   string
			}) string { return f.label })
		if err != nil {
			return "", fmt.Errorf("用户取消选择")
		}
		if choice.val == "custom" {
			custom := prompt.Ask("请输入小时数（1-999）", "6")
			n, err := strconv.Atoi(strings.TrimSpace(custom))
			if err != nil || n < 1 || n > 999 {
				return "", fmt.Errorf("无效的小时数: %s", custom)
			}
			return fmt.Sprintf("%d", n), nil
		}
		return choice.val, nil
	}

	// 非交互默认 6 小时
	return "6", nil
}
