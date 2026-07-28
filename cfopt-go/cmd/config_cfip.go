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

// cfipParam 描述 cf-ip.json 中的一个可配置参数。
type cfipParam struct {
	Index       int    // 显示序号
	Section     string // "cfst" 或 "speed_test"
	Key         string // JSON key
	Label       string // 中文标签
	DefaultVal  string // 默认值字符串
	CurrentVal  string // 当前值字符串
	ValueType   string // "int", "float", "bool", "string"
}

// newConfigCFIPCmd 构造 `cfopt config cfip` 命令。
func newConfigCFIPCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cfip",
		Short: "交互式配置 CF-IP 测速参数（cf-ip.json）",
		Long:  "逐一查看并修改 cfst 测速参数（线程数、端口、地区等）和 speed_test 参数（同步IP数等）。修改后自动保存到 cf-ip.json。",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigCFIP()
		},
	}
}

// runConfigCFIP 交互式 CF-IP 参数配置。
func runConfigCFIP() error {
	if !prompt.IsInteractive() {
		fmt.Println("config cfip 为交互式菜单，当前非交互终端。")
		fmt.Println("请直接编辑 cf-ip.json 文件，或运行 `cfopt config init` 生成模板。")
		return nil
	}

	path := filepath.Join(cfgDir, "cf-ip.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return common.Wrap("config:cfip:read", fmt.Errorf("无法读取 %s: %w\n请先运行 `cfopt config init` 或快速部署生成配置文件", path, err))
	}

	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return common.Wrap("config:cfip:parse", err)
	}

	// 获取或创建 cfst 段
	cfstSection, ok := raw["cfst"].(map[string]interface{})
	if !ok {
		cfstSection = make(map[string]interface{})
		raw["cfst"] = cfstSection
	}
	speedSection, ok := raw["speed_test"].(map[string]interface{})
	if !ok {
		speedSection = make(map[string]interface{})
		raw["speed_test"] = speedSection
	}

	// 定义所有参数
	params := buildCFIPParams(cfstSection, speedSection)

	for {
		fmt.Println()
		fmt.Println("=== CF-IP 参数配置 ===")
		fmt.Println()
		fmt.Println("CFST 参数:")
		for _, p := range params {
			if p.Section == "cfst" {
				fmt.Printf("  %2d) %-20s = %s\n", p.Index, p.Label, formatValue(p.CurrentVal, p.ValueType))
			}
		}
		fmt.Println()
		fmt.Println("SpeedTest 参数:")
		for _, p := range params {
			if p.Section == "speed_test" {
				fmt.Printf("  %2d) %-20s = %s\n", p.Index, p.Label, formatValue(p.CurrentVal, p.ValueType))
			}
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
			fmt.Println("无效输入，请输入 1-19 之间的编号。")
			continue
		}

		param := &params[idx-1]
		editCFIPParam(param, cfstSection, speedSection)
	}

	// 写回 cf-ip.json
	updated, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return common.Wrap("config:cfip:marshal", err)
	}
	if err := os.WriteFile(path, updated, 0o644); err != nil {
		return common.Wrap("config:cfip:write", err)
	}
	fmt.Printf("✓ 已保存配置到 %s\n", path)
	return nil
}

// buildCFIPParams 构建参数列表，从当前配置中读取值。
func buildCFIPParams(cfstSection, speedSection map[string]interface{}) []cfipParam {
	params := []cfipParam{
		// CFST 参数
		{Index: 1, Section: "cfst", Key: "threads", Label: "线程数", DefaultVal: "200", ValueType: "int"},
		{Index: 2, Section: "cfst", Key: "ping_times", Label: "测试次数", DefaultVal: "4", ValueType: "int"},
		{Index: 3, Section: "cfst", Key: "port", Label: "端口", DefaultVal: "443", ValueType: "int"},
		{Index: 4, Section: "cfst", Key: "colo", Label: "地区", DefaultVal: "HKG,NRT", ValueType: "string"},
		{Index: 5, Section: "cfst", Key: "url", Label: "测速 URL", DefaultVal: "", ValueType: "string"},
		{Index: 6, Section: "cfst", Key: "download_count", Label: "下载次数", DefaultVal: "10", ValueType: "int"},
		{Index: 7, Section: "cfst", Key: "download_time", Label: "下载时长(秒)", DefaultVal: "10", ValueType: "int"},
		{Index: 8, Section: "cfst", Key: "latency_max", Label: "延迟上限(ms)", DefaultVal: "9999", ValueType: "float"},
		{Index: 9, Section: "cfst", Key: "packet_loss_max", Label: "丢包上限", DefaultVal: "1.00", ValueType: "float"},
		{Index: 10, Section: "cfst", Key: "speed_min", Label: "速度下限(MB/s)", DefaultVal: "0", ValueType: "float"},
		{Index: 11, Section: "cfst", Key: "show_count", Label: "显示数量", DefaultVal: "20", ValueType: "int"},
		{Index: 12, Section: "cfst", Key: "disable_download", Label: "禁用下载测速", DefaultVal: "false", ValueType: "bool"},
		{Index: 13, Section: "cfst", Key: "all_ip", Label: "全 IP 模式", DefaultVal: "false", ValueType: "bool"},
		{Index: 14, Section: "cfst", Key: "ip_file", Label: "自定义 IP 文件", DefaultVal: "", ValueType: "string"},
		{Index: 15, Section: "cfst", Key: "httping", Label: "HTTPing 模式", DefaultVal: "false", ValueType: "bool"},
		// SpeedTest 参数
		{Index: 16, Section: "speed_test", Key: "take_ip_num", Label: "同步IP数量", DefaultVal: "5", ValueType: "int"},
		{Index: 17, Section: "speed_test", Key: "max_retry", Label: "测速失败重试", DefaultVal: "3", ValueType: "int"},
		{Index: 18, Section: "speed_test", Key: "output_html", Label: "输出 HTML", DefaultVal: "true", ValueType: "bool"},
		{Index: 19, Section: "speed_test", Key: "enable_log", Label: "启用日志", DefaultVal: "true", ValueType: "bool"},
	}

	// 从当前配置中读取值
	for i := range params {
		p := &params[i]
		var section map[string]interface{}
		if p.Section == "cfst" {
			section = cfstSection
		} else {
			section = speedSection
		}
		if val, ok := section[p.Key]; ok {
			p.CurrentVal = fmt.Sprintf("%v", val)
		} else {
			p.CurrentVal = p.DefaultVal
		}
	}
	return params
}

// editCFIPParam 交互式修改单个参数。
func editCFIPParam(param *cfipParam, cfstSection, speedSection map[string]interface{}) {
	fmt.Printf("\n当前 %s = %s\n", param.Label, formatValue(param.CurrentVal, param.ValueType))

	newVal := prompt.Ask(fmt.Sprintf("输入新值（回车保持当前值 %s）", param.CurrentVal), param.CurrentVal)
	if newVal == param.CurrentVal {
		fmt.Println("值未变化。")
		return
	}

	var section map[string]interface{}
	if param.Section == "cfst" {
		section = cfstSection
	} else {
		section = speedSection
	}

	// 类型转换后写入
	switch param.ValueType {
	case "int":
		v, err := strconv.Atoi(newVal)
		if err != nil {
			fmt.Printf("无效整数: %s\n", newVal)
			return
		}
		section[param.Key] = v
		param.CurrentVal = newVal
	case "float":
		v, err := strconv.ParseFloat(newVal, 64)
		if err != nil {
			fmt.Printf("无效浮点数: %s\n", newVal)
			return
		}
		section[param.Key] = v
		param.CurrentVal = newVal
	case "bool":
		v := strings.ToLower(newVal) == "true" || newVal == "1" || newVal == "yes"
		section[param.Key] = v
		if v {
			param.CurrentVal = "true"
		} else {
			param.CurrentVal = "false"
		}
	case "string":
		section[param.Key] = newVal
		param.CurrentVal = newVal
	}
	fmt.Printf("✓ %s 已更新为 %s\n", param.Label, formatValue(param.CurrentVal, param.ValueType))
}

// formatValue 根据类型格式化显示值。
func formatValue(val, valType string) string {
	if val == "" {
		return "(空)"
	}
	switch valType {
	case "bool":
		if val == "true" || val == "1" {
			return "true"
		}
		return "false"
	default:
		return val
	}
}
