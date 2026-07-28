package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/deploy"
	"cfopt/internal/prompt"
)

// newConfigCommand 构造 `cfopt config` 父命令（init / validate / wizard 子命令）。
func newConfigCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "配置管理：init / validate / wizard",
	}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "init",
			Short: "生成默认配置模板",
			RunE: func(c *cobra.Command, a []string) error {
				if err := config.WriteDefaults(cfgDir); err != nil {
					return common.Wrap("cmd:config:init", err)
				}
				fmt.Printf("已生成配置模板到: %s\n", cfgDir)
				return nil
			},
		},
		&cobra.Command{
			Use:   "validate",
			Short: "校验配置 schema",
			RunE: func(c *cobra.Command, a []string) error {
				if _, err := config.LoadFresh(cfgDir); err != nil {
					return common.Wrap("cmd:config:validate", err)
				}
				fmt.Println("配置校验通过")
				return nil
			},
		},
		newConfigWizardCmd(),
		newConfigCFIPCmd(),
	)
	return cmd
}

// newConfigWizardCmd 构造 `cfopt config wizard` 命令。
func newConfigWizardCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "wizard",
		Short: "交互式配置向导",
		RunE: func(c *cobra.Command, a []string) error {
			return runWizard()
		},
	}
}

// runWizard 交互式配置向导：检测 TTY，非交互终端时给出手动指引。
// 真正写入配置（非空壳），复用 internal/deploy 校验与落盘逻辑。
func runWizard() error {
	return runWizardForProvider("")
}

// runWizardForProvider 针对指定服务商（空则交互询问）执行真问答式配置生成：
// 选服务商 → 静默凭证 → API 校验 → 自动取 Zone/域名 → 选线路 → 落盘 conf。
// 与 quickdeploy 共用 internal/deploy 校验与 deployWriteConfReload（共享逻辑，避免重复实现）。
func runWizardForProvider(provider string) error {
	if !prompt.IsInteractive() {
		fmt.Println("当前非交互终端（TTY），无法进入向导。请手动编辑配置文件：")
		fmt.Printf("  配置文件目录: %s\n", cfgDir)
		fmt.Println("  可先执行 `cfopt config init` 生成模板，或运行 `cfopt quickdeploy` 向导。")
		return nil
	}

	ctx := context.Background()
	if provider == "" {
		p, err := prompt.AskChoice("选择 DNS 服务商", []string{"cloudflare", "dnspod"},
			func(s string) string { return s })
		if err != nil {
			return nil // 用户取消
		}
		provider = p
	}

	plan := &deploy.DeployPlan{
		Provider:         provider,
		ScheduleInterval: "6h",
	}

	// 校验凭证并取回 Zone/域名，让用户选择。
	if provider == "cloudflare" {
		if err := quickdeployCloudflare(ctx, plan); err != nil {
			return err
		}
		plan.RecordName = prompt.Ask("Cloudflare 子域名（@=根域名，或 www 等）", "@")
	} else {
		if err := quickdeployDNSPod(ctx, plan); err != nil {
			return err
		}
		fmt.Printf("可用线路枚举: %v（单线路直接回车；多线路输入编号如 1,3）\n", deploy.DNSPodLineEnum)
		sel := prompt.Ask("选择线路（编号逗号分隔，空=单线路默认）", "")
		plan.Lines = deploy.ParseLineSelection(sel)
	}

	// 落盘 conf + 重新加载（config.Load 有缓存，必须用 LoadFresh）。
	if err := deployWriteConfReload(plan); err != nil {
		return common.Wrap("cmd:config:wizard", err)
	}

	fmt.Printf("已生成配置: %s/%s（权限 0600）。\n", plan.ConfSubDir(), plan.ConfFileName())
	fmt.Println("可运行 `cfopt config validate` 校验，或 `cfopt sync` 立即同步。")
	return nil
}
