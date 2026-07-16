package cmd

import "github.com/spf13/cobra"

// newDNSCommand 构造 `cfopt dns` 父命令（cf / dnspod 子命令）。
func newDNSCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "dns",
		Short: "DNS 记录同步（Cloudflare / DNSPod）",
	}
	cmd.AddCommand(newDNSCfCmd(), newDNSPodCmd())
	return cmd
}
