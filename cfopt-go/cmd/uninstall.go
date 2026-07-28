package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/install"
	"cfopt/internal/prompt"
)

// uninstallSystem / uninstallDir / uninstallForce 对应 `cfopt uninstall` 的命令行标志。
// 提取为包级变量，便于 runUninstall() 复用与测试注入。
var (
	uninstallSystem bool
	uninstallDir    string
	uninstallForce  bool
)

// UninstallPlan 卸载计划（cmd 层交互选项结构，保留供后续扩展复用）。
type UninstallPlan struct {
	RemoveSchedule  bool // 停止并卸载调度
	RemoveGlobalCmd bool // 移除全局命令（PATH 项/软链）
	RemoveData      bool // 全清（含 conf/数据目录）；false=保留配置
}

// newUninstallCmd 构造 `cfopt uninstall` 命令：便携删目录 / 系统级清理全局命令与调度。
func newUninstallCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "卸载 cfopt（便携模式删除目录即干净退出 / 系统级清理 PATH 与调度）",
		Long: "默认便携模式：删除便携目录（含二进制/conf/数据）即干净退出，不触碰系统 PATH/注册表。\n" +
			"--system 走系统级：停止并卸载调度 → 移除全局命令(PATH/软链) → 删除安装目录（可选全清配置）。",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runUninstall()
		},
	}
	cmd.Flags().BoolVar(&uninstallSystem, "system", false, "系统级卸载：清理全局命令与调度（默认便携模式删除目录）")
	cmd.Flags().StringVar(&uninstallDir, "dir", "", "便携卸载目标目录（默认当前二进制所在目录）")
	cmd.Flags().BoolVar(&uninstallForce, "force", false, "跳过确认直接卸载（适合脚本/CI）")
	return cmd
}

// runUninstall 交互式卸载：判定模式 → 非交互拒绝/确认 → 系统级先卸载调度 → 调用 internal/install 清理。
func runUninstall() error {
	// 模式判定（Q-C3）：--system 走系统级；否则便携，--dir 优先，否则取当前二进制目录。
	var mode install.InstallMode
	var dir string
	if uninstallSystem {
		mode = install.ModeSystem
		dir = defaultInstallDir()
	} else {
		mode = install.ModePortable
		if uninstallDir != "" {
			dir = uninstallDir
		} else {
			exe, err := os.Executable()
			if err != nil {
				return common.Wrap("cmd:uninstall:exe", err)
			}
			dir = filepath.Dir(exe)
		}
	}

	// 非交互 + 无 --force → 拒绝并提示手动步骤（防静默误删）。
	if !prompt.IsInteractive() && !uninstallForce {
		fmt.Println("uninstall 为交互式操作，当前非交互终端且未指定 --force。")
		if mode == install.ModeSystem {
			fmt.Println("请交互终端运行 `cfopt uninstall --system` 清理全局命令与调度，或在脚本中明确传入 --force。")
		} else {
			fmt.Printf("请手动删除便携目录 %s（即可干净退出），或交互终端运行 `cfopt uninstall` 由程序代删。\n", dir)
		}
		return nil
	}

	// 交互默认 Confirm（No），防误删。
	if prompt.IsInteractive() && !uninstallForce {
		if !prompt.Confirm(fmt.Sprintf("确定卸载 cfopt 吗？（将以[%s]模式清理，默认保留配置）", modeLabel(mode)), false) {
			fmt.Println("已取消卸载。")
			return nil
		}
	}

	// 系统级：先停止并卸载调度（失败仅告警，不阻塞后续清理）。
	if mode == install.ModeSystem {
		if e := runSchedule("uninstall"); e != nil {
			common.Warn("cmd:uninstall: 调度卸载失败（可稍后手动处理）", "err", e.Error())
		}
	}

	opts := install.UninstallOptions{
		Mode:        mode,
		Dir:         dir,
		CfgDir:      cfgDir, // 系统级 RemoveData 清理目标；便携忽略
		RemoveData:  true,   // 便携恒全清；系统级默认全清，保留配置由下方交互选项覆盖
		SkipConfirm: uninstallForce,
	}

	// 系统级交互选范围：保留配置 / 全清。
	if mode == install.ModeSystem && prompt.IsInteractive() && !uninstallForce {
		choice, err := prompt.AskChoice("选择清理范围",
			[]string{"保留配置（仅移除全局命令与调度）", "全清（含配置与数据目录）"},
			func(s string) string { return s })
		if err != nil {
			fmt.Println("已取消卸载。")
			return nil
		}
		opts.RemoveData = choice == "全清（含配置与数据目录）"
	}

	res, err := install.RunUninstall(context.Background(), opts)
	if err != nil {
		return common.Wrap("cmd:uninstall", err)
	}
	printUninstallResult(res, mode, opts.RemoveData)
	return nil
}

// printUninstallResult 打印卸载结果汇总（列出已移除项与失败项，不静默跳过）。
// removeData 仅在系统级有意义：false 表示保留配置，打印提示引导「全清」。
func printUninstallResult(res *install.UninstallResult, mode install.InstallMode, removeData bool) {
	fmt.Println()
	fmt.Println("=== 卸载结果 ===")
	fmt.Printf("  模式: %s\n", modeLabel(mode))
	if len(res.Removed) > 0 {
		fmt.Println("  已移除:")
		for _, r := range res.Removed {
			fmt.Printf("    - %s\n", r)
		}
	} else {
		fmt.Println("  未移除任何内容。")
	}
	if len(res.Failed) > 0 {
		fmt.Println("  以下项清理失败（请手动处理）:")
		for _, f := range res.Failed {
			fmt.Printf("    - %s\n", f)
		}
		if mode == install.ModePortable {
			fmt.Println("  提示：Windows 下若 cfopt 正在运行，请退出本程序后手动删除该目录。")
		}
	}
	if len(res.Warnings) > 0 {
		fmt.Println("  警告:")
		for _, w := range res.Warnings {
			fmt.Printf("    - %s\n", w)
		}
	}
	fmt.Println()
	if mode == install.ModeSystem && !removeData {
		fmt.Println("配置已保留。如需彻底删除，可重新运行 `cfopt uninstall --system` 并选择「全清」。")
	}
}
