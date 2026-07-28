package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/dns"
	"cfopt/internal/history"
)

// newDNSCfCmd 构造 `cfopt dns cf` 命令：触发 CloudflareProvider.Sync。
func newDNSCfCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cf",
		Short: "Cloudflare DNS 记录同步",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			if cfg.CFDNS == nil {
				return common.New("cmd:dns:cf", "缺少 cf-dns 配置")
			}
			var hist history.HistoryStore
			if h, herr := newHistoryStore(cfg); herr == nil {
				hist = h
			}
			prov := dns.NewCloudflareProvider(cfg.CFDNS)
			if hist != nil {
				prov = dns.NewCloudflareProviderWithHistory(cfg.CFDNS, hist)
			}
			res, err := prov.Sync(context.Background(), cfg.CFDNS)
			if err != nil {
				return common.Wrap("cmd:dns:cf:sync", err)
			}
			fmt.Printf("Cloudflare 同步完成: updated=%d created=%d deleted=%d\n", res.Updated, res.Created, res.Deleted)
			return nil
		},
	}
}
