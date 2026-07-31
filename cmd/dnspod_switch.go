package cmd

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/prompt"
)

// newDNSPodSwitchCmd 构造 `cfopt dns dnspod switch`：交互式切换 DNSPod 工作模式
// （single ↔ isp_lines）与子域策略（separate ↔ unified），并落盘配置。
func newDNSPodSwitchCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "switch",
		Short: "切换 DNSPod 工作模式/子域策略（交互式）",
		Long:  "对应 Bash 原版 setup.sh 的 modify_work_mode / modify_subdomain_strategy。可选单值（dnspod.json）或多域名（dnspod/<domain>.conf）中的一个，切换其 Mode 与子域策略后落盘。",
		RunE: func(c *cobra.Command, a []string) error {
			return runDNSPodSwitch()
		},
	}
}

// runDNSPodSwitch 交互式切换 DNSPod 模式/策略并写回配置。
func runDNSPodSwitch() error {
	if !prompt.IsInteractive() {
		fmt.Println("dnspod switch 为交互式向导，当前非交互终端。")
		fmt.Println("可直接编辑 conf/dnspod/<域名>.conf 的 mode（single|isp_lines）与 sub_domain_unified（非空=统一子域）字段。")
		return nil
	}

	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	type domOption struct {
		label   string
		isMulti bool
		domain  string
	}
	var opts []domOption
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		opts = append(opts, domOption{label: "单值 dnspod.json (" + safeDomain(cfg.DNSPod.Domain) + ")", isMulti: false, domain: cfg.DNSPod.Domain})
	}
	for k, d := range cfg.DNSPodDomains {
		if d != nil && d.Enabled {
			opts = append(opts, domOption{label: "多域名 " + k, isMulti: true, domain: k})
		}
	}
	if len(opts) == 0 {
		fmt.Println("（未配置任何已启用的 DNSPod 域名）")
		fmt.Println("请先使用 `cfopt quickdeploy` 或 `cfopt config wizard` 添加 DNSPod 域名。")
		return nil
	}

	sel, err := prompt.AskChoice("选择要切换的 DNSPod 域名", opts, func(d domOption) string { return d.label })
	if err != nil {
		return nil // 用户取消
	}

	cur := cfg.DNSPod
	if sel.isMulti {
		cur = cfg.DNSPodDomains[sel.domain]
	}
	if cur == nil {
		return common.New("cmd:dnspod:switch", "目标配置为空")
	}
	// 多域名条目可能未显式填 Domain，用 key 补全，便于建默认线路。
	if strings.TrimSpace(cur.Domain) == "" {
		cur.Domain = sel.domain
	}

	modeDesc := cur.Mode
	if modeDesc == "" {
		modeDesc = "single"
	}
	stratDesc := "separate"
	if cur.SubDomainUnified != "" {
		stratDesc = "unified"
	}
	fmt.Printf("\n当前配置：Mode=%s，子域策略=%s\n", modeDesc, stratDesc)

	// 切换工作模式
	newMode, err := prompt.AskChoice("切换工作模式", []string{"single", "isp_lines"},
		func(s string) string {
			desc := map[string]string{"single": "（单线路）", "isp_lines": "（多运营商分流）"}
			return s + " " + desc[s]
		})
	if err != nil {
		return nil
	}
	config.ToggleDNSPodMode(cur, newMode)

	// 切换子域策略
	newStrat, err := prompt.AskChoice("切换子域策略", []string{"separate", "unified"},
		func(s string) string {
			desc := map[string]string{"separate": "（各线路独立子域）", "unified": "（统一子域）"}
			return s + " " + desc[s]
		})
	if err != nil {
		return nil
	}
	config.ToggleDNSPodStrategy(cur, newStrat == "unified")

	// 写回配置
	if sel.isMulti {
		if err := config.WriteDNSPodDomainConf(cfgDir, sel.domain, cur); err != nil {
			return common.Wrap("cmd:dnspod:switch:write", err)
		}
	} else {
		if err := config.Save(cfgDir, cfg); err != nil {
			return common.Wrap("cmd:dnspod:switch:save", err)
		}
	}
	afterStrat := "separate"
	if cur.SubDomainUnified != "" {
		afterStrat = "unified"
	}
	fmt.Printf("✓ 已更新 %s：Mode=%s，子域策略=%s\n", sel.domain, cur.Mode, afterStrat)

	if prompt.Confirm("是否立即同步该域名以应用新配置？", false) {
		return runSyncSingle("dnspod", sel.domain)
	}
	return nil
}

// safeDomain 占位：domain 为空时显示占位串，避免菜单项显示空。
func safeDomain(d string) string {
	if strings.TrimSpace(d) == "" {
		return "（未命名）"
	}
	return d
}
