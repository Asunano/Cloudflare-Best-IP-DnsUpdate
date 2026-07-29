package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/dns"
)

// DNSPod 删除模式相关命令行开关（映射到 DNSPodConfig.DeleteMode）。
// 默认不删除（DeleteMode=none，固化语义）；显式开启删除需 --yes 二次确认。
var (
	dnspodFlagDelete          bool // --delete：删除统一子域 + 非默认线路记录（unified-non-default）
	dnspodFlagDeleteUnified   bool // --delete-unified：仅删除统一子域记录（unified）
	dnspodFlagDeleteUnifiedND bool // --delete-unified-non-default：同 unified-non-default
	dnspodFlagYes             bool // --yes：跳过删除确认提示（非交互/调度场景）
)

// newDNSPodCmd 构造 `cfopt dns dnspod` 命令：触发 DNSPodProvider.Sync（含多运营商分流）。
func newDNSPodCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "dnspod",
		Short: "DNSPod DNS 记录同步（含多运营商分流）",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			if cfg.DNSPod == nil {
				return common.New("cmd:dns:dnspod", "缺少 dnspod 配置")
			}

			// 命令行删除开关覆盖配置 DeleteMode（显式优先）。
			if mode := resolveDNSPodDeleteMode(); mode != "" {
				if !dnspodFlagYes {
					return common.New("cmd:dns:dnspod", "删除模式已启用，需显式 --yes 确认（避免误删线上记录）")
				}
				common.Warn("dnspod: 删除模式已启用", "mode", mode)
				cfg.DNSPod.DeleteMode = mode
			}

			prov := dns.NewDNSPodProviderWithDataDir(cfg.DNSPod, dns.ResolveDataDir(cfg))
			res, err := prov.Sync(context.Background(), cfg.DNSPod)
			if err != nil {
				return common.Wrap("cmd:dns:dnspod:sync", err)
			}
			fmt.Printf("DNSPod 同步完成: updated=%d created=%d deleted=%d\n", res.Updated, res.Created, res.Deleted)
			if len(res.Errors) > 0 {
				fmt.Printf("部分线路错误: %v\n", res.Errors)
			}
			printWarnings(res.Warnings)
			return nil
		},
	}
	cmd.Flags().BoolVar(&dnspodFlagDelete, "delete", false, "启用删除（统一子域 + 非默认线路记录）")
	cmd.Flags().BoolVar(&dnspodFlagDeleteUnified, "delete-unified", false, "仅删除统一子域记录")
	cmd.Flags().BoolVar(&dnspodFlagDeleteUnifiedND, "delete-unified-non-default", false, "删除统一子域 + 非默认线路记录（保留默认线路）")
	cmd.Flags().BoolVar(&dnspodFlagYes, "yes", false, "确认删除操作（必需）")
	cmd.AddCommand(newDNSPodSwitchCmd())
	return cmd
}

// resolveDNSPodDeleteMode 将删除开关解析为 DeleteMode 值（优先级：unified-non-default > unified > delete）。
// 全关时返回空串，表示沿用配置/默认 none。
func resolveDNSPodDeleteMode() string {
	switch {
	case dnspodFlagDeleteUnifiedND, dnspodFlagDelete:
		return "unified-non-default"
	case dnspodFlagDeleteUnified:
		return "unified"
	default:
		return ""
	}
}
