package cmd

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/cfst"
	"cfopt/internal/config"
	"cfopt/internal/install"
	"cfopt/internal/prompt"
	"cfopt/internal/scheduler"
)

// healthIssue 单个健康检查项的结果。
type healthIssue struct {
	Name    string // 检查项名称，如 "cfst 二进制"
	Status  string // "ok" | "fail"
	Detail  string // 详情描述
	Fix     string // 修复建议
	fixable bool   // 是否可自动修复
}

// newHealthCmd 构造 `cfopt health` 命令：系统健康检测看板。
func newHealthCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "health",
		Short: "系统健康检测（检查 cfst/配置/网络/调度等 6 项，支持自动修复）",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runHealthCheck()
		},
	}
}

// runHealthCheck 执行六项健康检测并展示结果，检测完成后询问是否修复。
func runHealthCheck() error {
	fmt.Println()
	fmt.Println("=== 系统健康检测 ===")
	fmt.Println()

	issues := runAllChecks()
	printHealthResults(issues)

	passCount := 0
	for _, iss := range issues {
		if iss.Status == "ok" {
			passCount++
		}
	}
	fmt.Printf("\n  共 %d/%d 通过，%d 项异常\n", passCount, len(issues), len(issues)-passCount)
	fmt.Println()

	// 有异常项时询问是否修复
	if passCount < len(issues) && prompt.IsInteractive() {
		return askAutoFix(issues)
	}
	return nil
}

// runAllChecks 执行全部 6 项健康检测。
func runAllChecks() []healthIssue {
	var issues []healthIssue

	// 1) cfst 二进制检查
	issues = append(issues, checkCFSTBinary())

	// 2) 配置文件检查
	issues = append(issues, checkConfigFiles())

	// 3) 数据目录检查
	issues = append(issues, checkDataDirs())

	// 4) 网络连通性检查
	issues = append(issues, checkNetwork())

	// 5) 调度服务状态
	issues = append(issues, checkScheduleStatus())

	// 6) 历史错误检查
	issues = append(issues, checkHistoryErrors())

	return issues
}

// checkCFSTBinary 检查 cfst 测速二进制是否存在。
func checkCFSTBinary() healthIssue {
	iss := healthIssue{Name: "cfst 二进制", fixable: true}
	if cfstBinaryExists() {
		// 找出 cfst 的路径用于显示
		binName := "cfst"
		if runtime.GOOS == "windows" {
			binName = "cfst.exe"
		}
		paths := []string{
			filepath.Join(cfgDir, "assets", "cfst", binName),
		}
		if cwd, err := os.Getwd(); err == nil {
			paths = append(paths, filepath.Join(cwd, "assets", "cfst", binName))
		}
		if exe, err := os.Executable(); err == nil {
			paths = append(paths, filepath.Join(filepath.Dir(exe), "assets", "cfst", binName))
		}
		foundPath := ""
		for _, p := range paths {
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
				foundPath = p
				break
			}
		}
		iss.Status = "ok"
		iss.Detail = fmt.Sprintf("就绪 (%s)", foundPath)
	} else {
		iss.Status = "fail"
		iss.Detail = "缺失"
		iss.Fix = "请运行 `cfopt cfst fetch` 下载 cfst 测速二进制"
	}
	return iss
}

// checkConfigFiles 检查配置文件完整性。
func checkConfigFiles() healthIssue {
	iss := healthIssue{Name: "配置文件", fixable: true}

	// 检查必需的配置文件
	missingFiles := []string{}
	jsonFiles := []string{"global.json", "cf-dns.json", "dnspod.json"}
	for _, f := range jsonFiles {
		if _, err := os.Stat(filepath.Join(cfgDir, f)); os.IsNotExist(err) {
			missingFiles = append(missingFiles, f)
		}
	}

	// 检查 conf/cf-dns/*.conf
	cfDNSEntries, _ := os.ReadDir(filepath.Join(cfgDir, "cf-dns"))
	hasCFDNS := false
	for _, e := range cfDNSEntries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".conf") {
			hasCFDNS = true
			break
		}
	}

	// 检查 conf/dnspod/*.conf
	dnspodEntries, _ := os.ReadDir(filepath.Join(cfgDir, "dnspod"))
	hasDNSPod := false
	for _, e := range dnspodEntries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".conf") {
			hasDNSPod = true
			break
		}
	}

	var details []string
	if len(missingFiles) > 0 {
		details = append(details, fmt.Sprintf("缺失 %d 个: %s", len(missingFiles), strings.Join(missingFiles, ", ")))
	} else {
		details = append(details, "JSON 配置完整")
	}
	if !hasCFDNS {
		details = append(details, "cf-dns 无 .conf 配置")
	}
	if !hasDNSPod {
		details = append(details, "dnspod 无 .conf 配置")
	}

	if len(missingFiles) > 0 {
		iss.Status = "fail"
		iss.Detail = strings.Join(details, "；")
		iss.Fix = "请运行 `cfopt config init` 生成默认配置模板"
	} else {
		iss.Status = "ok"
		iss.Detail = strings.Join(details, "；")
	}
	return iss
}

// checkDataDirs 检查数据目录是否可写。
func checkDataDirs() healthIssue {
	iss := healthIssue{Name: "数据目录", fixable: false}

	// 检查并创建 assets/data/ 和 assets/cfst/。
	// 注意基准是进程 cwd 而非 cfgDir：同步链路实际读写的是 ./assets/data
	//（internal/sync/sync.go、dns.ResolveDataDir），历史上误检 conf/assets 导致
	// "health 全绿但同步报 no such file or directory"。
	dirs := []string{
		filepath.Join("assets", "data"),
		filepath.Join("assets", "cfst"),
	}
	var failedDirs []string
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			failedDirs = append(failedDirs, d)
			continue
		}
		// 尝试写入临时文件检查可写性
		tmp := filepath.Join(d, ".cfopt-write-test")
		if err := os.WriteFile(tmp, []byte("test"), 0o600); err != nil {
			failedDirs = append(failedDirs, d)
		} else {
			_ = os.Remove(tmp)
		}
	}

	if len(failedDirs) > 0 {
		iss.Status = "fail"
		iss.Detail = fmt.Sprintf("不可写: %s", strings.Join(failedDirs, ", "))
		iss.Fix = fmt.Sprintf("建议: chmod -R 755 %s", strings.Join(failedDirs, " "))
	} else {
		iss.Status = "ok"
		iss.Detail = "可写"
	}
	return iss
}

// checkNetwork 检查网络连通性。
func checkNetwork() healthIssue {
	iss := healthIssue{Name: "网络连接", fixable: false}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	warns := install.HealthPing(ctx)
	if len(warns) == 0 {
		iss.Status = "ok"
		iss.Detail = "所有目标可达"
	} else {
		iss.Status = "fail"
		iss.Detail = strings.Join(warns, "; ")
		iss.Fix = "请检查网络环境与防火墙设置"
	}
	return iss
}

// checkScheduleStatus 检查调度服务运行状态（支持双保底：系统服务 + crontab/schtasks）。
func checkScheduleStatus() healthIssue {
	iss := healthIssue{Name: "调度服务", fixable: true}

	// 优先检查系统服务状态。
	// 注意：kardianos 把 systemd `activating` 也判为 running，而 Restart=always 的
	// 崩溃重启循环恰好长期处于 activating(auto-restart) —— 必须用 detectRestartLoop
	// 二次甄别，否则坏单元（如旧版缺 ExecStart 参数）会被误报为正常。
	st, err := scheduler.NewDaemonStatusOnly().Status()
	if err == nil && st == "running" {
		if loop, detail := detectRestartLoop(); loop {
			iss.Status = "fail"
			iss.Detail = "服务处于崩溃重启循环（" + detail + "）"
			iss.Fix = "服务单元可能已损坏或过旧，请运行 `cfopt schedule uninstall` 后重新 `cfopt schedule install` 并 `start`"
			return iss
		}
		iss.Status = "ok"
		iss.Detail = "running"
		return iss
	}

	// 其次检查备选调度：
	// - 非 Windows：crontab
	// - Windows：schtasks（计划任务）
	if runtime.GOOS == "windows" {
		if checkSchtasksExists() {
			iss.Status = "ok"
			iss.Detail = "schtasks"
			return iss
		}
	} else {
		hasCron := checkCrontabExists()
		if hasCron {
			iss.Status = "ok"
			iss.Detail = "crontab"
			return iss
		}
	}

	iss.Status = "fail"
	iss.Detail = "未运行"
	if runtime.GOOS == "windows" {
		iss.Fix = "请运行 `cfopt schedule install` 安装系统服务，或 `cfopt schedule install-schtasks` 使用计划任务"
	} else {
		iss.Fix = "请运行 `cfopt schedule install` 或 `cfopt schedule install-cron` 注册调度"
	}
	return iss
}

// detectRestartLoop 检测 systemd 单元是否处于崩溃重启循环（仅 Linux 有 systemctl 时生效）。
// 判据：SubState=auto-restart，或 NRestarts 异常偏大（>5 即视为循环）。
// 无 systemd / 查询失败时返回 false（不产生误报，交由上层状态判断）。
func detectRestartLoop() (bool, string) {
	if runtime.GOOS != "linux" {
		return false, ""
	}
	out, err := exec.Command("systemctl", "show", "cfopt",
		"-p", "SubState", "-p", "NRestarts").Output()
	if err != nil {
		return false, ""
	}
	subState, nRestarts := "", 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if v, ok := strings.CutPrefix(line, "SubState="); ok {
			subState = strings.TrimSpace(v)
		} else if v, ok := strings.CutPrefix(line, "NRestarts="); ok {
			nRestarts, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if subState == "auto-restart" || nRestarts > 5 {
		return true, fmt.Sprintf("SubState=%s, 已重启 %d 次", subState, nRestarts)
	}
	return false, ""
}

// SystemdServiceStatus 返回 cfopt systemd 服务的可读状态（仅 Linux 生效）。
// 覆盖：未安装（单元不存在）/ 运行中（含崩溃重启循环甄别）/ 已停止 / 启动失败 / 未知。
// 非 Linux 或无 systemctl 时返回空串，调用方据此跳过显示（如 Windows 走 schtasks、容器无 systemd）。
func SystemdServiceStatus() string {
	if runtime.GOOS != "linux" {
		return ""
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return ""
	}
	out, err := exec.Command("systemctl", "show", "cfopt",
		"-p", "LoadState", "-p", "ActiveState", "-p", "SubState").Output()
	if err != nil {
		return "未知（systemctl 查询失败）"
	}
	var load, active, sub string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		switch {
		case strings.HasPrefix(line, "LoadState="):
			load = strings.TrimPrefix(line, "LoadState=")
		case strings.HasPrefix(line, "ActiveState="):
			active = strings.TrimPrefix(line, "ActiveState=")
		case strings.HasPrefix(line, "SubState="):
			sub = strings.TrimPrefix(line, "SubState=")
		}
	}
	switch {
	case load == "not-found":
		return "未安装（systemd 单元 cfopt 不存在）"
	case active == "failed":
		return "启动失败（failed）"
	case active == "active":
		if sub == "auto-restart" {
			return "运行中（崩溃重启循环，需排查）"
		}
		return "运行中（running）"
	case active == "inactive":
		return "已停止（stopped）"
	default:
		return "未知（" + active + "）"
	}
}

// checkSchtasksExists 检查 Windows 计划任务是否存在。
func checkSchtasksExists() bool {
	out, err := exec.Command("schtasks", "/query", "/tn", "CFOPT_Sync", "/fo", "CSV", "/nh").CombinedOutput()
	return err == nil && strings.Contains(string(out), "CFOPT_Sync")
}

// crontabHasCfopt 判断给定 crontab 内容中是否包含 cfopt 调度条目。
// 与 installCronSchedule / uninstallCronSchedule 使用同一标记 "schedule run --once"。
func crontabHasCfopt(content string) bool {
	return strings.Contains(content, "schedule run --once")
}

// checkCrontabExists 检查是否存在 cfopt 相关的 crontab 条目。
func checkCrontabExists() bool {
	out, err := exec.Command("crontab", "-l").Output()
	if err != nil {
		// 无 crontab（crontab -l 非零退出）或 crontab 不可用，视为不存在。
		return false
	}
	return crontabHasCfopt(string(out))
}

// checkHistoryErrors 检查 history.jsonl 中是否有最近错误。
func checkHistoryErrors() healthIssue {
	iss := healthIssue{Name: "历史错误", fixable: false}

	histPath := filepath.Join(cfgDir, "assets", "data", "history.jsonl")
	if _, err := os.Stat(histPath); os.IsNotExist(err) {
		// 也可能在数据目录
		histPath = filepath.Join(".", "assets", "data", "history.jsonl")
		if _, err := os.Stat(histPath); os.IsNotExist(err) {
			iss.Status = "ok"
			iss.Detail = "无历史记录"
			return iss
		}
	}

	f, err := os.Open(histPath)
	if err != nil {
		iss.Status = "ok"
		iss.Detail = "无法读取历史记录"
		return iss
	}
	defer func() { _ = f.Close() }()

	// 读取最后 20 行检查是否有 "error" 关键词
	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
		if len(lines) > 20 {
			lines = lines[1:]
		}
	}

	errorCount := 0
	for _, line := range lines {
		if strings.Contains(strings.ToLower(line), "error") ||
			strings.Contains(strings.ToLower(line), "\"success\":false") {
			errorCount++
		}
	}

	if errorCount > 0 {
		iss.Status = "fail"
		iss.Detail = fmt.Sprintf("最近 %d 条记录中发现 %d 个错误", len(lines), errorCount)
		iss.Fix = "请运行 `cfopt schedule status` 查看详细历史"
	} else {
		iss.Status = "ok"
		iss.Detail = "最近运行正常"
	}
	return iss
}

// printHealthResults 格式化打印健康检测结果。
func printHealthResults(issues []healthIssue) {
	for _, iss := range issues {
		mark := "✓"
		if iss.Status != "ok" {
			mark = "✗"
		}
		fmt.Printf("  %s %s:\t%s\n", mark, iss.Name, iss.Detail)
		if iss.Status != "ok" && iss.Fix != "" {
			fmt.Printf("    → 修复建议: %s\n", iss.Fix)
		}
	}
}

// askAutoFix 检测完成后询问是否修复异常项。
func askAutoFix(issues []healthIssue) error {
	// 收集可修复的异常项
	var fixableIssues []healthIssue
	var fixableIdx []int
	for i, iss := range issues {
		if iss.Status != "ok" && iss.fixable {
			fixableIssues = append(fixableIssues, iss)
			fixableIdx = append(fixableIdx, i)
		}
	}

	if len(fixableIssues) == 0 {
		return nil
	}

	fmt.Printf("检测到 %d 项可修复异常，是否需要尝试修复？\n", len(fixableIssues))
	choice, err := prompt.AskChoice("选择修复方式", []string{
		"全部修复",
		"选择修复",
		"不修复",
	}, func(s string) string { return s })
	if err != nil {
		return nil // 用户取消
	}

	switch choice {
	case "全部修复":
		fixed, _ := autoFix(fixableIssues, fixableIdx, issues)
		fmt.Printf("\n✓ 已自动修复 %d 项\n", fixed)
	case "选择修复":
		// 逐项询问
		fixed := 0
		for i, iss := range fixableIssues {
			fmt.Println()
			confirm := prompt.Confirm(fmt.Sprintf("修复「%s」? (%s)", iss.Name, iss.Fix), true)
			if confirm {
				idx := fixableIdx[i]
				if doFix(issues, idx) {
					fixed++
				}
			}
		}
		fmt.Printf("\n✓ 已修复 %d 项\n", fixed)
	case "不修复":
		fmt.Println("跳过修复，请稍后手动处理。")
	}

	return nil
}

// autoFix 自动修复所有可修复项，返回已修复数量。
func autoFix(fixableIssues []healthIssue, fixableIdx []int, allIssues []healthIssue) (fixed int, err error) {
	for i, iss := range fixableIssues {
		fmt.Printf("正在修复「%s」... ", iss.Name)
		idx := fixableIdx[i]
		if doFix(allIssues, idx) {
			fixed++
			fmt.Println("✓")
		} else {
			fmt.Println("✗")
		}
	}
	return fixed, nil
}

// doFix 执行单个修复项，返回是否修复成功。
func doFix(issues []healthIssue, idx int) bool {
	switch idx {
	case 0: // cfst 二进制
		destDir := filepath.Join(".", "assets", "cfst")
		if exe, err := os.Executable(); err == nil {
			destDir = filepath.Join(filepath.Dir(exe), "assets", "cfst")
		}
		if err := os.MkdirAll(destDir, 0o755); err != nil {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
		defer cancel()
		_, err := cfst.Fetch(ctx, cfst.CFSTFetchOptions{
			DestDir:    destDir,
			Timeout:    120 * time.Second,
			AutoMirror: true,
		})
		if err == nil {
			issues[idx].Status = "ok"
			return true
		}
		return false

	case 1: // 配置文件
		if err := config.WriteDefaults(cfgDir); err != nil {
			return false
		}
		issues[idx].Status = "ok"
		return true

	case 4: // 调度服务
		// 先尝试 start（如果已安装过运行中）
		if err := runSchedule("start"); err == nil {
			issues[idx].Status = "ok"
			return true
		}
		// start 失败则尝试 install + start
		if err := runSchedule("install"); err == nil {
			if err := runSchedule("start"); err == nil {
				issues[idx].Status = "ok"
				return true
			}
		}
		// 都失败：打印具体原因，引导 crontab 备选
		fmt.Println()
		fmt.Println("  提示：系统服务安装失败，便携模式可尝试备选调度（crontab 定时任务）：")
		if runtime.GOOS == "windows" {
			fmt.Println("    cfopt schedule install-schtasks")
		} else {
			fmt.Println("    cfopt schedule install-cron")
		}
		return false

	default:
		return false
	}
}
