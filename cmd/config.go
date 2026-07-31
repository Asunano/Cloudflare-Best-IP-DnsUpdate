package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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
		Short: "配置管理：init / validate / wizard / cfip",
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
		&cobra.Command{
			Use:   "migrate",
			Short: "迁移遗留配置：将 cf-dns/ 与 dnspod/ 下的 *.json 重命名为 *.conf（兼容 Bash 版）",
			Long:  "Bash 版多域名配置使用 *.json 扩展名，Go 版使用 *.conf。本命令将遗留的 *.json 域名配置原子重命名为 *.conf（内容同为 JSON，无需改动）。目标 *.conf 已存在则跳过，幂等可执行。",
			RunE: func(c *cobra.Command, a []string) error {
				return runConfigMigrate()
			},
		},
	)
	return cmd
}

// runConfigMigrate 将 cf-dns/ 与 dnspod/ 下遗留的 *.json 域名配置重命名为 *.conf。
// 幂等：目标 *.conf 已存在则跳过该文件；写入采用 temp + rename 原子替换，完成后删除原 *.json。
func runConfigMigrate() error {
	subdirs := []string{"cf-dns", "dnspod"}
	var renamed, skipped, failed int
	for _, sub := range subdirs {
		dir := filepath.Join(cfgDir, sub)
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue // 目录不存在，视为无遗留配置
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}
			stem := strings.TrimSuffix(e.Name(), ".json")
			src := filepath.Join(dir, e.Name())
			dst := filepath.Join(dir, stem+".conf")
			if _, err := os.Stat(dst); err == nil {
				skipped++
				continue
			}
			data, rerr := os.ReadFile(src)
			if rerr != nil {
				failed++
				common.Warn("config:migrate: 读取失败，跳过", "file", src, "err", rerr.Error())
				continue
			}
			tmp := dst + ".migrate.tmp"
			if werr := os.WriteFile(tmp, data, 0o600); werr != nil {
				failed++
				common.Warn("config:migrate: 写临时文件失败，跳过", "file", tmp, "err", werr.Error())
				continue
			}
			if rerr := os.Rename(tmp, dst); rerr != nil {
				failed++
				common.Warn("config:migrate: 重命名失败，跳过", "file", src, "err", rerr.Error())
				_ = os.Remove(tmp)
				continue
			}
			if rerr := os.Remove(src); rerr != nil {
				common.Warn("config:migrate: 删除原 .json 失败（.conf 已生成）", "file", src, "err", rerr.Error())
			}
			renamed++
		}
	}
	fmt.Printf("配置迁移完成：重命名 %d 个，跳过 %d 个（目标 .conf 已存在），失败 %d 个。\n", renamed, skipped, failed)
	if renamed > 0 {
		fmt.Println("建议随后运行 `cfopt config validate` 校验迁移结果。")
	}
	return nil
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
		fmt.Printf("可用线路枚举: %v（0=全选；单线路直接回车；多线路输入编号如 1,3）\n", deploy.DNSPodLineEnum)
		sel := prompt.Ask("选择线路（0=全选，逗号分隔多选，空=单线路默认）", "")
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
