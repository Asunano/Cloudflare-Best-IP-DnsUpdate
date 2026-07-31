package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/deploy"
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
			if e.IsDir() || !isDomainConfName(e.Name()) {
				continue
			}
			domain := strings.TrimSuffix(strings.TrimSuffix(e.Name(), ".conf"), ".json")
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
		records, _ := deploy.ReadDeployRecords(cfgDir)
		deployAt := make(map[string]time.Time)
		for _, r := range records {
			k := strings.ToLower(r.Domain)
			if t, ok := deployAt[k]; !ok || r.CreatedAt.After(t) {
				deployAt[k] = r.CreatedAt
			}
		}
		for i, e := range entries {
			atStr := "—"
			if at, ok := deployAt[strings.ToLower(e.domain)]; ok && !at.IsZero() {
				atStr = at.Format("2006-01-02 15:04")
			}
			fmt.Printf("  %d) %-12s %-24s 部署: %s\n", i+1, e.provider, e.domain, atStr)
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
			"编辑域名配置",
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
		case "编辑域名配置":
			if err := editDomainConfig(entry.confPath); err != nil {
				fmt.Printf("编辑配置失败: %v\n", err)
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

	// 部署时间（若有部署记录）
	if recs, rerr := deploy.ReadDeployRecords(cfgDir); rerr == nil {
		for _, r := range recs {
			if strings.EqualFold(r.Domain, entry.domain) {
				fmt.Printf("  部署时间: %s\n", r.CreatedAt.Format("2006-01-02 15:04:05"))
				break
			}
		}
	}

	fmt.Println()
	return nil
}

// editColoForDomain 交互式修改域名配置中的 speed_test_colo 设置。
// colo 写入域名配置文件（cf-dns/{domain}.conf / dnspod/{domain}.conf），
// 不再触及 cf-ip.json（测速链路优先读取域名配置的 speed_test_colo）。
func editColoForDomain(entry domainEntry) error {
	commonColos := []string{"HKG,LAX,SIN,NRT", "HKG,SIN,SEA", "LAX,NRT,HKG", "SIN,HKG,LAX,SJC", ""}
	coloSel, err := prompt.AskChoice("选择新的测速区域", commonColos,
		func(s string) string {
			labels := map[string]string{
				"HKG,LAX,SIN,NRT":  "大陆推荐：香港（HKG）洛杉矶（LAX）新加坡（SIN）东京（NRT）",
				"HKG,SIN,SEA":      "移动推荐：HKG SIN SEA",
				"LAX,NRT,HKG":      "联通推荐：LAX NRT HKG",
				"SIN,HKG,LAX,SJC":  "电信推荐：SIN HKG LAX SJC",
			}
			if label, ok := labels[s]; ok {
				return label
			}
			return "不限制（测速所有区域）"
		})
	if err != nil {
		return nil // 用户取消
	}

	// 写入域名配置文件的 speed_test_colo 字段。
	data, rerr := os.ReadFile(entry.confPath)
	if rerr != nil {
		return common.Wrap("editColo:read", rerr)
	}
	var raw map[string]interface{}
	if uerr := json.Unmarshal(data, &raw); uerr != nil {
		return common.Wrap("editColo:parse", uerr)
	}
	raw["speed_test_colo"] = coloSel
	updated, merr := json.MarshalIndent(raw, "", "  ")
	if merr != nil {
		return common.Wrap("editColo:marshal", merr)
	}
	if werr := os.WriteFile(entry.confPath, updated, 0o600); werr != nil {
		return common.Wrap("editColo:write", werr)
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
