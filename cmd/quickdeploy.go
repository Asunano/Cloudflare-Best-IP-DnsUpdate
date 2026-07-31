package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/cfst"
	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/deploy"
	"cfopt/internal/prompt"
	"cfopt/internal/sync"
)

// syncRunner 执行「首次测速 + 同步」主链路（可被测试替换为 no-op，避免依赖真实 cfst 二进制/网络）。
// domain 非空时作为 DomainFilter，只处理该域名（用于快速部署单域名场景，避免测速串扰）。
// providers 为可选过滤参数，传空时同步全部已启用模块。
var syncRunner = func(ctx context.Context, cfgDir, domain string, providers ...string) (*sync.SyncSummary, error) {
	cfg, err := config.LoadFresh(cfgDir)
	if err != nil {
		return nil, common.Wrap("quickdeploy:load", err)
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return nil, common.Wrap("quickdeploy:history", err)
	}
	syncer, err := sync.BuildSyncerFromConfig(cfg, hist)
	if err != nil {
		return nil, common.Wrap("quickdeploy:build", err)
	}
	syncer.DomainFilter = domain
	return syncer.SyncAll(ctx, cfg, nil, providers...)
}

// scheduleInstaller 安装并启动计划任务式调度（可被测试替换）。
var scheduleInstaller = func() error {
	if err := runSchedule("install"); err != nil {
		return err
	}
	return runSchedule("start")
}

// newQuickdeployCmd 构造 `cfopt quickdeploy` 命令：单域名（单/多线路）向导。
func newQuickdeployCmd() *cobra.Command {
	var installSchedule bool
	cmd := &cobra.Command{
		Use:   "quickdeploy",
		Short: "快速部署单域名（Cloudflare/DNSPod，支持单/多线路）",
		Long:  "交互式向导：静默输入 Token → 自动校验并取回 Zone/域名 → 生成 600 权限 conf → 首次测速同步 → 安装调度。把五步压成一次向导。",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runQuickdeploy(installSchedule)
		},
	}
	cmd.Flags().BoolVar(&installSchedule, "schedule", true, "部署后安装计划任务式调度（默认每 6 小时）")
	return cmd
}

// cfstBinaryExists 检查 cfst 测速二进制是否存在。
// 检查 cfgDir 层级（assets/cfst/cfst[.exe]）以及 dir/assets/cfst/cfst[.exe]。
func cfstBinaryExists() bool {
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	// 检查 cfgDir 级别的 assets/cfst
	paths := []string{
		filepath.Join(cfgDir, "assets", "cfst", binName),
	}
	// 也检查当前工作目录下的 assets/cfst
	if cwd, err := os.Getwd(); err == nil {
		paths = append(paths, filepath.Join(cwd, "assets", "cfst", binName))
	}
	// 检查 exe 同目录下的 assets/cfst
	if exe, err := os.Executable(); err == nil {
		paths = append(paths, filepath.Join(filepath.Dir(exe), "assets", "cfst", binName))
	}
	for _, p := range paths {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return true
		}
	}
	return false
}

// autoFetchCFST 自动下载 cfst 测速二进制到 assets/cfst/ 目录。
// 优先使用 exe 同目录，回退到当前工作目录。返回 true 表示下载成功。
func autoFetchCFST() bool {
	destDir := filepath.Join(".", "assets", "cfst")
	if exe, err := os.Executable(); err == nil {
		destDir = filepath.Join(filepath.Dir(exe), "assets", "cfst")
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		fmt.Printf("⚠ 创建目录失败: %v\n", err)
		return false
	}
	fmt.Println("正在下载 cfst...")
	_, err := cfst.Fetch(context.Background(), cfst.CFSTFetchOptions{
		DestDir:    destDir,
		Timeout:    120 * time.Second,
		AutoMirror: true,
	})
	if err != nil {
		fmt.Printf("⚠ 下载 cfst 失败: %v\n", err)
		return false
	}
	return true
}

// runQuickdeploy 交互式快速部署向导。
func runQuickdeploy(installSchedule bool) error {
	if !prompt.IsInteractive() {
		fmt.Println("quickdeploy 为交互式向导，当前非交互终端。")
		fmt.Println("请手动在 conf/<provider>/<域名>.conf 创建配置，或运行 `cfopt config wizard`。")
		return nil
	}

	// cfst 预检：缺失则询问是否自动下载，不让用户走完向导才发现缺二进制。
	if !cfstBinaryExists() {
		fmt.Println("⚠ 检测到 cfst 测速二进制不存在，快速部署需要 cfst 完成测速。")
		fmt.Println("  将自动下载到 assets/cfst/ 目录。")
		if !prompt.Confirm("是否立即自动下载 cfst？", true) {
			fmt.Println("将跳过 cfst 下载继续（首次同步会失败，需稍后手动 `cfopt cfst fetch`）。")
		} else if autoFetchCFST() {
			fmt.Println("✓ cfst 下载完成，继续快速部署向导。")
		} else {
			fmt.Println("下载失败或用户取消，请稍后手动 `cfopt cfst fetch` 下载。")
		}
	}

	ctx := context.Background()

	// 1) 选服务商
	provider, err := prompt.AskChoice("选择 DNS 服务商", []string{"cloudflare", "dnspod"},
		func(s string) string { return s })
	if err != nil {
		return nil // 用户取消
	}

	plan := &deploy.DeployPlan{
		Provider:         provider,
		ScheduleInterval: "6h",
	}

	// 2) 静默凭证 + 3) 校验并取 Zone/域名（最多 3 次重试）
	if provider == "cloudflare" {
		if err := quickdeployCloudflare(ctx, plan); err != nil {
			return err
		}
	} else {
		if err := quickdeployDNSPod(ctx, plan); err != nil {
			return err
		}
	}

	// 4) 选线路（CF 单记录；DNSPod 支持单/多线路）
	if provider == "dnspod" {
		fmt.Printf("可用线路枚举: %v（0=全选；单线路直接回车；多线路输入编号如 1,3）\n", deploy.DNSPodLineEnum)
		sel := prompt.Ask("选择线路（0=全选，逗号分隔多选，空=单线路默认）", "")
		plan.Lines = deploy.ParseLineSelection(sel)
	} else {
		plan.RecordName = prompt.Ask("Cloudflare 子域名（@=根域名，或 www 等）", "@")
	}

	// 4b) 选择测速地区（colo），留空则跳过（cfst 不对地区过滤）。
	//     多线路 DNSPod：每条线路独立选择测速区域。
	if provider == "dnspod" && len(plan.Lines) > 1 {
		plan.LineColo = make(map[string]string, len(plan.Lines))
		coloNames := map[string]string{
			"HKG,LAX,SIN,NRT": "大陆推荐：香港（HKG）洛杉矶（LAX）新加坡（SIN）东京（NRT）",
			"HKG,SIN,SEA":     "移动推荐：HKG SIN SEA",
			"LAX,NRT,HKG":     "联通推荐：LAX NRT HKG",
			"SIN,HKG,LAX,SJC": "电信推荐：SIN HKG LAX SJC",
		}
		coloOpts := []string{"HKG,LAX,SIN,NRT", "HKG,SIN,SEA", "LAX,NRT,HKG", "SIN,HKG,LAX,SJC", ""}
		for _, line := range plan.Lines {
			coloSel, coloErr := prompt.AskChoice(fmt.Sprintf("选择 [%s] 线路的测速区域", line), coloOpts,
				func(s string) string {
					if label, ok := coloNames[s]; ok {
						return label
					}
					return "不限制（测速所有区域）"
				})
			if coloErr != nil {
				return coloErr // 用户取消 → 终止部署
			}
			if coloSel != "" {
				plan.LineColo[line] = coloSel
			}
		}
	} else {
		var commonColos = []string{"HKG,LAX,SIN,NRT", "HKG,SIN,SEA", "LAX,NRT,HKG", "SIN,HKG,LAX,SJC", ""}
		coloSel, coloErr := prompt.AskChoice("选择测速区域", commonColos,
			func(s string) string {
				labels := map[string]string{
					"HKG,LAX,SIN,NRT": "大陆推荐：香港（HKG）洛杉矶（LAX）新加坡（SIN）东京（NRT）",
					"HKG,SIN,SEA":     "移动推荐：HKG SIN SEA",
					"LAX,NRT,HKG":     "联通推荐：LAX NRT HKG",
					"SIN,HKG,LAX,SJC": "电信推荐：SIN HKG LAX SJC",
				}
				if label, ok := labels[s]; ok {
					return label
				}
				return "不限制（测速所有区域）"
			})
		if coloErr != nil {
			return coloErr // 用户取消 → 终止部署
		}
		if coloSel != "" {
			plan.Colo = coloSel
		}
	}

	// 4c) 选择同步 IP 数量
	takeIPNumStr := prompt.Ask("同步 IP 数量（每次同步提取的最优 IP 条数）", "2")
	if num, parseErr := strconv.Atoi(strings.TrimSpace(takeIPNumStr)); parseErr == nil && num > 0 {
		plan.TakeIPNum = num
	}

	// 5)+6)+7) 落盘 → 同步 → 调度 → 摘要
	scheduleInstalled, err := quickDeployCore(ctx, plan, installSchedule)
	if err != nil {
		return err
	}

	printDeploySummary(plan, scheduleInstalled)
	return nil
}

// quickdeployCloudflare 收集并校验 Cloudflare 凭证，取回 Zone 让用户选择域名。
func quickdeployCloudflare(ctx context.Context, plan *deploy.DeployPlan) error {
	for attempt := 0; attempt < 3; attempt++ {
		token, _ := prompt.AskSecret("Cloudflare API Token")
		plan.Token = token
		zones, err := deploy.ValidateCloudflare(ctx, token)
		if err != nil {
			fmt.Printf("Token 校验失败：%v\n", err)
			if !prompt.Confirm("是否重新输入 Token？", true) {
				return fmt.Errorf("用户放弃 Cloudflare 凭证输入")
			}
			continue
		}
		if len(zones) == 0 {
			return fmt.Errorf("该 Token 无可访问的 Zone，请确认权限")
		}
		zone, zerr := prompt.AskChoice("选择要部署的域名（Zone）", zones,
			func(z deploy.Zone) string { return z.Name })
		if zerr != nil {
			return fmt.Errorf("用户取消域名选择")
		}
		plan.ZoneID = zone.ID
		plan.Domain = zone.Name
		return nil
	}
	return fmt.Errorf("Cloudflare 凭证校验重试次数用尽")
}

// quickdeployDNSPod 收集并校验 DNSPod 凭证，取回域名让用户选择。
func quickdeployDNSPod(ctx context.Context, plan *deploy.DeployPlan) error {
	for attempt := 0; attempt < 3; attempt++ {
		plan.SecretID, _ = prompt.AskSecret("DNSPod SecretID")
		plan.SecretKey, _ = prompt.AskSecret("DNSPod SecretKey")
		domains, err := deploy.ValidateDNSPod(ctx, plan.SecretID, plan.SecretKey)
		if err != nil {
			fmt.Printf("凭证校验失败：%v\n", err)
			if !prompt.Confirm("是否重新输入凭证？", true) {
				return fmt.Errorf("用户放弃 DNSPod 凭证输入")
			}
			continue
		}
		if len(domains) == 0 {
			return fmt.Errorf("该凭证无可访问的域名，请确认权限")
		}
		domain, derr := prompt.AskChoice("选择要部署的域名", domains,
			func(s string) string { return s })
		if derr != nil {
			return fmt.Errorf("用户取消域名选择")
		}
		plan.Domain = domain
		plan.SubDomain = prompt.Ask("DNSPod 子域名（默认 www）", "www")
		return nil
	}
	return fmt.Errorf("DNSPod 凭证校验重试次数用尽")
}

// writeDeployConf 将 plan 转为 conf 结构并落盘到 <cfgDir>/<provider>/<domain>.conf（权限 0600）。
// 注意：cfgDir 本身即「配置目录」，loader 直接扫描 cfgDir/dnspod 与 cfgDir/cf-dns（无额外 conf 前缀）。
func writeDeployConf(plan *deploy.DeployPlan) error {
	confDir := filepath.Join(cfgDir, plan.ConfSubDir())
	if err := os.MkdirAll(confDir, 0o755); err != nil {
		return common.Wrap("quickdeploy:mkdir", err)
	}
	v, err := plan.BuildConf()
	if err != nil {
		return common.Wrap("quickdeploy:build-conf", err)
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return common.Wrap("quickdeploy:marshal", err)
	}
	p := filepath.Join(confDir, plan.ConfFileName())
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return common.Wrap("quickdeploy:write", err)
	}
	return nil
}

// deployWriteConfReload 确保基础配置骨架存在、落盘新域名 conf（权限 600），
// 并用 config.LoadFresh 重新扫描（config.Load 有 sync.Once 缓存，必须用 LoadFresh 才能读到新 conf）。
// 不含同步与调度，供 quickdeploy 与 config wizard 共用。
func deployWriteConfReload(plan *deploy.DeployPlan) error {
	if err := config.WriteDefaults(cfgDir); err != nil {
		return common.Wrap("deploy:init-conf", err)
	}
	if err := writeDeployConf(plan); err != nil {
		return common.Wrap("deploy:write-conf", err)
	}
	if _, err := config.LoadFresh(cfgDir); err != nil {
		return common.Wrap("deploy:load-fresh", err)
	}
	return nil
}

// quickDeployCore 落盘 conf → 重新加载配置 → 首次测速同步 → 安装调度。
// 校验应在调用前由交互层完成；此处聚焦编排。
// 返回 scheduleInstalled（调度是否成功安装）与错误。
func quickDeployCore(ctx context.Context, plan *deploy.DeployPlan, installSchedule bool) (scheduleInstalled bool, err error) {
	if err := deployWriteConfReload(plan); err != nil {
		return false, err
	}

	// 部署记录持久化 + 重复部署检测（对应 Bash deploy_record.json）。
	if deploy.IsDomainDeployed(cfgDir, plan.Domain) {
		common.Warn("quickdeploy: 该域名此前已部署，本次将更新部署记录", "domain", plan.Domain)
	}
	if err := deploy.AppendDeployRecord(cfgDir, deploy.DeployRecord{
		Provider:         plan.Provider,
		Domain:           plan.Domain,
		SubDomain:        plan.SubDomain,
		ZoneID:           plan.ZoneID,
		Lines:            plan.Lines,
		Colo:             plan.Colo,
		TakeIPNum:        plan.TakeIPNum,
		ScheduleInterval: plan.ScheduleInterval,
		ConfPath:         filepath.Join(plan.ConfSubDir(), plan.ConfFileName()),
	}); err != nil {
		common.Warn("quickdeploy: 写入部署记录失败", "err", err.Error())
	}

	// 首次测速 + 同步（仅同步本次部署的域名，不串扰其它已启用模块）。
	providerID := plan.Provider
	if providerID == "cloudflare" {
		providerID = "cf"
	}
	// 计算完整域名用于 DomainFilter：DNSPod 拼上 sub_domain，CF 直接用根域名。
	fullDomain := strings.TrimSpace(plan.Domain)
	if providerID == "dnspod" {
		if sub := strings.TrimSpace(plan.SubDomain); sub != "" && sub != "@" {
			fullDomain = sub + "." + fullDomain
		}
	}
	if _, err := syncRunner(ctx, cfgDir, fullDomain, providerID); err != nil {
		common.Warn("quickdeploy: 首次同步未完成（可稍后 `cfopt sync` 重试）", "err", err.Error())
		fmt.Printf("提示：首次同步未完成（%v）。部署配置已落盘，稍后可在主菜单执行同步。\n", err)
		// 同步失败若涉及 cfst 缺失，增加醒目提示（4c）
		if strings.Contains(err.Error(), "cfst") {
			fmt.Println("\n📌 提示：同步需 cfst 测速二进制，请运行 `cfopt cfst fetch` 下载后重试同步。")
		}
	}
	// 安装计划任务式调度（默认 6h）。
	if installSchedule {
		if err := scheduleInstaller(); err != nil {
			common.Warn("quickdeploy: 调度安装失败", "err", err.Error())
			fmt.Printf("提示：调度安装失败（%v），可稍后在调度中心重新安装。\n", err)
			return false, nil
		}
		return true, nil
	}
	return false, nil
}

// printDeploySummary 打印部署摘要。
func printDeploySummary(plan *deploy.DeployPlan, scheduleInstalled bool) {
	fmt.Println()
	fmt.Println("=== 快速部署完成 ===")
	fmt.Printf("  服务商:    %s\n", plan.Provider)
	fmt.Printf("  域名:      %s\n", plan.Domain)
	if plan.Provider == "cloudflare" {
		fmt.Printf("  子域名:    %s\n", plan.RecordName)
		fmt.Printf("  Zone ID:   %s\n", plan.ZoneID)
	} else {
		fmt.Printf("  子域名:    %s\n", plan.SubDomain)
		fmt.Printf("  线路:      %v\n", plan.Lines)
	}
	if plan.Colo != "" {
		fmt.Printf("  测速地区:  %s\n", plan.Colo)
	}
	fmt.Printf("  配置文件:  %s/%s\n", plan.ConfSubDir(), plan.ConfFileName())
	fmt.Printf("  调度:      %s（每 %s）\n", yesNo(scheduleInstalled), plan.ScheduleInterval)
}
