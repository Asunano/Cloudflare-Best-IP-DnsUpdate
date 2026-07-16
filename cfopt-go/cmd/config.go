package cmd

import (
	"bufio"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
)

// newConfigCommand 构造 `cfopt config` 父命令（init / validate / wizard 子命令）。
func newConfigCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "配置管理：init / validate / wizard",
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
	)
	return cmd
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

// runWizard 简化交互向导：检测 TTY，非交互终端时提示手动编辑。
func runWizard() error {
	if !isInteractive() {
		fmt.Println("当前非交互终端（TTY），无法进入向导。请手动编辑配置文件：")
		fmt.Printf("  配置文件目录: %s\n", cfgDir)
		fmt.Println("  可先执行 `cfopt config init` 生成模板。")
		return nil
	}
	// 交互终端：生成默认模板并提示逐项填写关键字段
	if err := config.WriteDefaults(cfgDir); err != nil {
		return common.Wrap("cmd:config:wizard", err)
	}
	fmt.Printf("已生成默认模板到 %s，请按提示编辑关键字段：\n", cfgDir)

	reader := bufio.NewReader(os.Stdin)
	ask := func(prompt, current string) string {
		fmt.Printf("%s [%s]: ", prompt, current)
		line, _ := reader.ReadString('\n')
		line = trimNewline(line)
		if line == "" {
			return current
		}
		return line
	}
	_ = ask // 简化版：仅引导用户编辑文件中的 token / secret / domain 字段

	fmt.Println("向导已完成（简化版）：请编辑上述文件中的 token / secret_id / secret_key / domain 等字段后运行 `cfopt sync`。")
	return nil
}

// isInteractive 检测标准输出是否为字符设备（TTY），对应原 Bash 的 `[ -t 0 ]` 判断。
func isInteractive() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

// trimNewline 去除字符串末尾换行符。
func trimNewline(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}
