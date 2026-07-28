package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"cfopt/internal/common"
	"cfopt/internal/prompt"
)

type domainEntry struct {
	provider string // "Cloudflare" 或 "DNSPod"
	domain   string
	confPath string // 配置文件完整路径
}

// runListConfigs 扫描 cfgDir/cf-dns/ 和 cfgDir/dnspod/ 目录下的 *.conf 文件，
// 用表格格式展示已配置的域名。交互终端下支持选择域名后查看详情/编辑/删除。
func runListConfigs() error {
	fmt.Println()
	fmt.Println("=== 已配置域名 ===")

	type providerInfo struct {
		label string
		dir   string
	}
	providers := []providerInfo{
		{"Cloudflare", filepath.Join(cfgDir, "cf-dns")},
		{"DNSPod", filepath.Join(cfgDir, "dnspod")},
	}

	var entries []domainEntry
	for _, p := range providers {
		dirEntries, err := os.ReadDir(p.dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			fmt.Fprintf(os.Stderr, "警告：无法读取 %s: %v\n", p.dir, err)
			continue
		}
		for _, e := range dirEntries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".conf") {
				continue
			}
			domain := strings.TrimSuffix(e.Name(), ".conf")
			entries = append(entries, domainEntry{
				provider: p.label,
				domain:   domain,
				confPath: filepath.Join(p.dir, e.Name()),
			})
		}
	}

	if len(entries) == 0 {
		fmt.Println("  （未配置任何域名）")
		fmt.Println("  请使用「快速部署」添加域名。")
		fmt.Printf("  共 0 个域名\n")
		fmt.Println()
		return nil
	}

	// 非交互终端：打印表格列表后返回
	if !prompt.IsInteractive() {
		for i, e := range entries {
			fmt.Printf("  %d) %-12s %s\n", i+1, e.provider, e.domain)
		}
		fmt.Printf("  共 %d 个域名\n", len(entries))
		fmt.Println()
		return nil
	}

	// 交互模式：略过表格列表，直接进入 AskChoice（AskChoice 自己会打印选项）

	// 交互式选择域名进入管理
	selected, err := prompt.AskChoice("选择要管理的域名（0=返回）", entries,
		func(e domainEntry) string { return e.provider + " " + e.domain })
	if err != nil {
		return nil // 用户取消
	}

	return manageDomainConfig(selected)
}

// manageDomainConfig 显示域名配置详情并提供编辑子菜单。
func manageDomainConfig(entry domainEntry) error {
	// 读取并显示配置详情
	if err := displayConfDetail(entry); err != nil {
		common.Warn("list: 读取配置详情失败", "err", err.Error())
		fmt.Printf("警告：读取配置详情失败: %v\n", err)
	}

	// 编辑子菜单
	for {
		action, err := prompt.AskChoice("选择操作", []string{
			"修改 colo（测速区域）",
			"修改 CF-IP 参数（线程/端口/同步数量等）",
			"删除此配置",
			"返回主菜单",
		}, func(s string) string { return s })
		if err != nil {
			return nil // 用户取消
		}
		switch action {
		case "修改 colo（测速区域）":
			if err := editColoForDomain(entry); err != nil {
				fmt.Printf("修改 colo 失败: %v\n", err)
			}
		case "修改 CF-IP 参数（线程/端口/同步数量等）":
			if err := runConfigCFIP(); err != nil {
				fmt.Printf("修改 CF-IP 参数失败: %v\n", err)
			}
		case "删除此配置":
			if err := deleteDomainConfig(entry); err != nil {
				fmt.Printf("删除配置失败: %v\n", err)
			}
			// 删除后不再继续编辑
			return nil
		case "返回主菜单":
			return nil
		}
	}
}

// displayConfDetail 读取并打印域名配置详情。
func displayConfDetail(entry domainEntry) error {
	data, err := os.ReadFile(entry.confPath)
	if err != nil {
		return common.Wrap("list:read", err)
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return common.Wrap("list:parse", err)
	}

	fmt.Printf("\n=== 域名配置详情 ===\n")
	fmt.Printf("  服务商: %s\n", entry.provider)
	fmt.Printf("  域名:   %s\n", entry.domain)

	if entry.provider == "Cloudflare" {
		if v, ok := raw["api"].(map[string]interface{}); ok {
			if z, ok := v["zone_id"]; ok {
				fmt.Printf("  Zone ID: %v\n", z)
			}
		}
		if v, ok := raw["dns"].(map[string]interface{}); ok {
			if r, ok := v["record_name"]; ok {
				fmt.Printf("  子域名:  %v\n", r)
			}
		}
	} else {
		if v, ok := raw["sub_domain"]; ok {
			fmt.Printf("  子域名:  %v\n", v)
		}
		if v, ok := raw["mode"]; ok {
			fmt.Printf("  模式:    %v\n", v)
		}
	}

	// 读取当前 colo 设置
	cfIPPath := filepath.Join(cfgDir, "cf-ip.json")
	if cfData, cfErr := os.ReadFile(cfIPPath); cfErr == nil {
		var cfRaw map[string]interface{}
		if json.Unmarshal(cfData, &cfRaw) == nil {
			if cfst, ok := cfRaw["cfst"].(map[string]interface{}); ok {
				if c, ok := cfst["colo"]; ok && fmt.Sprint(c) != "" {
					fmt.Printf("  测速地区: %v\n", c)
				} else {
					fmt.Printf("  测速地区: 不限\n")
				}
			}
		}
	}
	fmt.Println()
	return nil
}

// editColoForDomain 交互式修改 cf-ip.json 中的 colo 设置。
func editColoForDomain(entry domainEntry) error {
	commonColos := []string{"HKG,NRT", "HKG,NRT,LAX", "HKG", "NRT", "LAX", "SJC", "SEA", ""}
	coloSel, err := prompt.AskChoice("选择新的测速区域（留空=不限地区）", commonColos,
		func(s string) string {
			if s == "" {
				return "不限（测速所有区域）"
			}
			return s
		})
	if err != nil {
		return nil // 用户取消
	}
	if err := saveColoToConfig(cfgDir, coloSel); err != nil {
		return err
	}
	if coloSel == "" {
		fmt.Printf("✓ 已清除 %s 的测速地区限制（不限地区）\n", entry.domain)
	} else {
		fmt.Printf("✓ 已更新 %s 的测速地区为: %s\n", entry.domain, coloSel)
	}
	return nil
}

// deleteDomainConfig 确认后删除域名配置文件。
func deleteDomainConfig(entry domainEntry) error {
	fmt.Printf("\n⚠ 即将删除配置: %s (%s)\n", entry.domain, entry.provider)
	fmt.Printf("  文件: %s\n", entry.confPath)
	if !prompt.Confirm("确认删除此配置？此操作不可恢复", false) {
		fmt.Println("已取消删除。")
		return nil
	}
	if err := os.Remove(entry.confPath); err != nil {
		return common.Wrap("list:delete", err)
	}
	fmt.Printf("✓ 已删除配置: %s\n", entry.domain)
	return nil
}
