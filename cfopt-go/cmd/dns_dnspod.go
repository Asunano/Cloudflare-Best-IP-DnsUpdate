package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/dns"
)

// newDNSPodCmd 构造 `cfopt dns dnspod` 命令：触发 DNSPodProvider.Sync（含多运营商分流）。
func newDNSPodCmd() *cobra.Command {
	return &cobra.Command{
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
			prov := dns.NewDNSPodProvider(cfg.DNSPod)
			res, err := prov.Sync(context.Background(), cfg.DNSPod)
			if err != nil {
				return common.Wrap("cmd:dns:dnspod:sync", err)
			}
			fmt.Printf("DNSPod 同步完成: updated=%d created=%d deleted=%d\n", res.Updated, res.Created, res.Deleted)
			if len(res.Errors) > 0 {
				fmt.Printf("部分线路错误: %v\n", res.Errors)
			}
			return nil
		},
	}
}
