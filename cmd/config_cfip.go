package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/prompt"
)

// cfipParam 描述域名配置中的一个可编辑参数。
type cfipParam struct {
	Index       int
	JSONPath    string // 如 "dns.record_name"、"speed_test_colo"
	Label       string
	DefaultVal  string
	ValueType   string // "int" / "string" / "bool"
	CurrentVal  interface{}
}

// newConfigCFIPCmd 构造 `cfopt config cfip` 命令。
func newConfigCFIPCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cfip [domain]",
		Short: "交互式编辑域名配置文件",
		Long:  "读取并编辑 cf-dns/ 或 dnspod/ 下的域名配置文件，修改后自动保存。",
		RunE: func(c *cobra.Command, args []string) error {
			return runConfigCFIP(args)
		},
	}
}

// editDomainConfig 编辑指定路径的域名配置文件（供 manageDomainConfig 内部调用）。
func editDomainConfig(confPath string) error {
	if !prompt.IsInteractive() {
		fmt.Println("当前非交互终端。请直接编辑配置文件。")
		return nil
	}

	data, err := os.ReadFile(confPath)
	if err != nil {
		return common.Wrap("cfip:read", fmt.Errorf("无法读取 %s: %w", confPath, err))
	}

	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return common.Wrap("cfip:parse", err)
	}

	params := buildDomainParams(raw)

	for {
		fmt.Println()
		fmt.Println("=== 域名配置参数 ===")
		for _, p := range params {
			fmt.Printf("  %2d) %-24s = %s\n", p.Index, p.Label, formatValue(p.CurrentVal, p.ValueType))
		}
		fmt.Println()
		fmt.Println("  0) 保存并退出")
		fmt.Println()

		sel := prompt.Ask("请输入要修改的参数编号", "0")
		sel = strings.TrimSpace(sel)
		if sel == "0" {
			break
		}
		idx, err := strconv.Atoi(sel)
		if err != nil || idx < 1 || idx > len(params) {
			fmt.Printf("无效输入，请输入 1-%d 之间的编号。\n", len(params))
			continue
		}

		param := &params[idx-1]
		editDomainParam(param, raw)
	}

	updated, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return common.Wrap("cfip:marshal", err)
	}
	if err := os.WriteFile(confPath, updated, 0o600); err != nil {
		return common.Wrap("cfip:write", err)
	}
	fmt.Printf("✓ 已保存配置到 %s\n", confPath)
	return nil
}

// runConfigCFIP 交互式域名配置编辑（命令行入口）。
// args[0] 可选域名，省略时列出可用域名让用户选择。
func runConfigCFIP(args []string) error {
	confPath, err := resolveDomainConfPath(args)
	if err != nil {
		return err
	}
	return editDomainConfig(confPath)
}

// resolveDomainConfPath 解析参数确定域名配置文件路径。
// 带参数时直接读取对应域名配置；无参数时列出可用域名让用户选择。
func resolveDomainConfPath(args []string) (string, error) {
	if len(args) > 0 && args[0] != "" {
		// 省略逻辑：直接尝试拼接
		for _, sub := range []string{"cf-dns", "dnspod"} {
			p := filepath.Join(cfgDir, sub, args[0]+".conf")
			if _, err := os.Stat(p); err == nil {
				return p, nil
			}
			p = filepath.Join(cfgDir, sub, args[0]+".json")
			if _, err := os.Stat(p); err == nil {
				return p, nil
			}
		}
		return "", fmt.Errorf("未找到域名 %q 的配置文件（已扫描 cf-dns/、dnspod/）", args[0])
	}

	// 无参数：扫描可用域名
	type domainOption struct {
		label    string
		confPath string
	}
	var options []domainOption
	for _, sub := range []string{"cf-dns", "dnspod"} {
		dir := filepath.Join(cfgDir, sub)
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if !strings.HasSuffix(name, ".conf") && !strings.HasSuffix(name, ".json") {
				continue
			}
			opts := domainOption{
				label:    sub + "/" + strings.TrimSuffix(name, filepath.Ext(name)),
				confPath: filepath.Join(dir, name),
			}
			options = append(options, opts)
		}
	}
	if len(options) == 0 {
		return "", fmt.Errorf("未找到任何域名配置文件（%s/{cf-dns,dnspod}/*.conf）", cfgDir)
	}
	toLabel := func(o domainOption) string { return o.label }
	choice, err := prompt.AskChoice("选择要编辑的域名", options, toLabel)
	if err != nil {
		return "", fmt.Errorf("用户取消")
	}
	return choice.confPath, nil
}

// buildDomainParams 从域名配置 JSON 构建可编辑参数列表。
func buildDomainParams(raw map[string]interface{}) []cfipParam {
	var params []cfipParam
	idx := 0

	addParam := func(jsonPath, label, defaultVal, valueType string, current interface{}) {
		idx++
		params = append(params, cfipParam{
			Index:      idx,
			JSONPath:   jsonPath,
			Label:      label,
			DefaultVal: defaultVal,
			ValueType:  valueType,
			CurrentVal: current,
		})
	}

	// enabled
	addParam("enabled", "启用", "true", "bool", raw["enabled"])

	// dns.*
	if dns, ok := raw["dns"].(map[string]interface{}); ok {
		addParam("dns.record_name", "子域名", "@", "string", dns["record_name"])
		addParam("dns.domain", "根域名", "", "string", dns["domain"])
		addParam("dns.max_ips_per_record", "每记录 IP 数", "2", "int", dns["max_ips_per_record"])
	}

	// ip_source.*
	if ips, ok := raw["ip_source"].(map[string]interface{}); ok {
		addParam("ip_source.file_path", "IP 源文件路径", "", "string", ips["file_path"])
		addParam("ip_source.auto_refresh", "自动刷新 IP 源", "true", "bool", ips["auto_refresh"])
		addParam("ip_source.refresh_interval_hours", "刷新间隔(小时)", "6", "int", ips["refresh_interval_hours"])
	}

	// 测速相关
	addParam("speed_test_colo", "测速地区", "HKG,NRT", "string", raw["speed_test_colo"])
	addParam("take_ip_num", "同步 IP 数量", "5", "int", raw["take_ip_num"])

	// api.*
	if api, ok := raw["api"].(map[string]interface{}); ok {
		addParam("api.timeout", "API 超时(秒)", "10", "int", api["timeout"])
		addParam("api.max_retries", "API 重试次数", "5", "int", api["max_retries"])
	}

	return params
}

// editDomainParam 交互式修改单参数，更新 raw。
func editDomainParam(param *cfipParam, raw map[string]interface{}) {
	promptStr := fmt.Sprintf("输入 %s 的新值", param.Label)
	defaultStr := formatValue(param.CurrentVal, param.ValueType)
	input := prompt.Ask(promptStr, defaultStr)
	input = strings.TrimSpace(input)

	setJSONValue(raw, param.JSONPath, parseValue(input, param.ValueType))
}

// setJSONValue 按点分路径设置 JSON 值（如 "dns.record_name"）。
func setJSONValue(raw map[string]interface{}, path string, val interface{}) {
	parts := strings.SplitN(path, ".", 2)
	if len(parts) == 1 {
		raw[parts[0]] = val
		return
	}
	if nested, ok := raw[parts[0]].(map[string]interface{}); ok {
		setJSONValue(nested, parts[1], val)
	} else {
		raw[parts[0]] = map[string]interface{}{}
		setJSONValue(raw, parts[1], val)
	}
}

// formatValue 格式化当前值用于显示。
func formatValue(v interface{}, valueType string) string {
	if v == nil {
		return "(未设置)"
	}
	switch valueType {
	case "bool":
		if b, ok := v.(bool); ok {
			return strconv.FormatBool(b)
		}
		if s, ok := v.(string); ok {
			return s
		}
	case "int":
		if f, ok := v.(float64); ok {
			return strconv.Itoa(int(f))
		}
		if s, ok := v.(string); ok {
			return s
		}
	}
	return fmt.Sprintf("%v", v)
}

// parseValue 将字符串输入转为目标类型的值。
func parseValue(input string, valueType string) interface{} {
	input = strings.TrimSpace(input)
	switch valueType {
	case "bool":
		switch strings.ToLower(input) {
		case "true", "yes", "1", "y":
			return true
		default:
			return false
		}
	case "int":
		if n, err := strconv.Atoi(input); err == nil {
			return n
		}
		return input
	default:
		return input
	}
}
