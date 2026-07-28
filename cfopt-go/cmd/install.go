package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/install"
	"cfopt/internal/prompt"
)

// installSystem / installDir / installSchedule / installForce 对应 `cfopt install` 的命令行标志。
// 提取为包级变量，便于 runInstall() 复用与测试注入。
var (
	installSystem   bool
	installDir      string
	installSchedule bool
	installForce    bool
)

// defaultInstallDir 返回默认自安置目录：Windows %LOCALAPPDATA%\cfopt；其他 /usr/local/bin。
func defaultInstallDir() string {
	if runtime.GOOS == "windows" {
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			return filepath.Join(local, "cfopt")
		}
		return filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local", "cfopt")
	}
	return "/usr/local/bin"
}

// newInstallCmd 构造 `cfopt install` 命令：便携优先 + 系统级可选，自安置 + 全局命令（可选）+ cfst 下载 + conf 骨架 + 网络体检（幂等）。
func newInstallCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "install",
		Short: "一键安装 cfopt（便携优先：二进制 + conf 骨架 + cfst，默认不写系统目录）",
		Long: "默认以便携模式运行：将二进制、conf 骨架与 cfst 测速二进制放在同一目录，不写 PATH、不写注册表、" +
			"不自复制到 LOCALAPPDATA；卸载即删除该目录。\n显式 --system 走系统级：自安置到标准目录 + 用户级 PATH +（可选）计划任务调度。",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInstall()
		},
	}
	cmd.Flags().BoolVar(&installSystem, "system", false, "系统级安装：自安置到标准目录并写用户级 PATH（默认便携模式）")
	cmd.Flags().StringVar(&installDir, "dir", "", "便携安装目标目录（默认当前二进制所在目录）；与 --system 互斥")
	cmd.Flags().BoolVar(&installSchedule, "schedule", false, "安装完成后注册并启动计划任务式调度（仅 --system 有效）")
	cmd.Flags().BoolVar(&installForce, "force", false, "跳过确认直接安装（适合脚本/CI）")
	return cmd
}

// runInstall 安装编排：判定便携/系统级、调用 internal/install、仅系统级调 runSchedule、打印 Windows GUI 提示。
func runInstall() error {
	// 模式判定（Q-C2：--system 优先于 --dir，忽略 --dir 并警告）。
	var mode install.InstallMode
	var dir string
	var cfgDir string
	if installSystem {
		mode = install.ModeSystem
		if installDir != "" {
			fmt.Fprintln(os.Stderr, "警告：--system 与 --dir 互斥，已忽略 --dir，使用系统默认安装目录。")
		}
		dir = defaultInstallDir()
		cfgDir = "conf" // 系统级沿用 global --config-dir 默认 conf
	} else {
		mode = install.ModePortable
		if installDir != "" {
			dir = installDir
		} else {
			exe, err := os.Executable()
			if err != nil {
				return common.Wrap("cmd:install:exe", err)
			}
			dir = filepath.Dir(exe)
		}
		cfgDir = filepath.Join(dir, "conf") // C1：配置落在 dir/conf，默认 cfopt（cwd=dir, cfgDir=conf）即可发现
	}

	// Q-C1：便携模式传 --schedule → 忽略并提示（调度为系统级能力）。
	schedule := installSchedule
	if mode == install.ModePortable && schedule {
		fmt.Println("提示：调度为系统级能力，请用 `cfopt install --system --schedule` 或安装后 `cfopt schedule install`。便携模式已忽略 --schedule。")
		schedule = false
	}

	// Windows GUI 推荐提示（纯 CLI 文案，不改 IPC/GUI 契约）。
	if runtime.GOOS == "windows" {
		printWindowsGuiHint()
	}

	// 非交互：直接幂等执行（不阻塞），但提示关键后续步骤。
	if !installForce && !prompt.IsInteractive() {
		fmt.Println("非交互模式：以幂等方式执行自安置（已存在项将跳过）。")
	}
	// 交互 + 无 --force：检查目标目录内容并确认。
	if prompt.IsInteractive() && !installForce {
		// 检查目录是否为空（仅含 cfopt 相关文件）
		exeName := "cfopt"
		if runtime.GOOS == "windows" {
			exeName = "cfopt.exe"
		}
		clean, foreignFiles, cErr := install.CheckDirClean(dir, exeName)
		if cErr != nil {
			fmt.Fprintf(os.Stderr, "警告：无法扫描目录 %s: %v\n", dir, cErr)
		} else if !clean {
			fmt.Printf("注意：目录 %s 非空，包含以下非 cfopt 文件：\n", dir)
			for _, f := range foreignFiles {
				fmt.Printf("  - %s\n", f)
			}
			if !prompt.Confirm("目录非空且包含非 cfopt 文件，是否继续安装？", false) {
				fmt.Println("已取消安装。")
				return nil
			}
		}
		if !prompt.Confirm(fmt.Sprintf("将在 %s 以[%s]模式安装 cfopt，是否继续？", dir, modeLabel(mode)), true) {
			fmt.Println("已取消安装。")
			return nil
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), installTimeout)
	defer cancel()

	opts := install.InstallOptions{
		Mode:         mode,
		Dir:          dir,
		CfgDir:       cfgDir,
		WithSchedule: schedule,
	}
	res, err := install.RunInstall(ctx, opts)
	if err != nil {
		return common.Wrap("cmd:install", err)
	}
	printInstallResult(res, dir)

	// 调度安装（仅系统级 + --schedule）：实际注册由 cmd 层 runSchedule 完成（install 包零调用）。
	if mode == install.ModeSystem && schedule {
		fmt.Println("正在安装计划任务式调度（默认每 6 小时）...")
		if e := runSchedule("install"); e != nil {
			common.Warn("cmd:install: 调度注册失败", "err", e.Error())
			res.Warnings = append(res.Warnings, "调度注册失败: "+e.Error())
		} else if e := runSchedule("start"); e != nil {
			common.Warn("cmd:install: 调度启动失败", "err", e.Error())
			res.Warnings = append(res.Warnings, "调度启动失败: "+e.Error())
		} else {
			res.ScheduleInstalled = true
			fmt.Println("计划任务式调度已安装并启动。")
		}
	}
	return nil
}

// installTimeout 安装整体超时（含 cfst 下载）。
const installTimeout = 180 * time.Second

// printInstallResult 打印自安置结果汇总。
func printInstallResult(res *install.InstallResult, dir string) {
	fmt.Println()
	fmt.Println("=== 安装结果 ===")
	fmt.Printf("  模式:          %s\n", modeLabel(res.Mode))
	fmt.Printf("  自安置目录:    %s\n", dir)
	fmt.Printf("  二进制自安置:  %s\n", yesNo(res.SelfPlaced))
	fmt.Printf("  全局命令:      %s\n", yesNo(res.GlobalCommandInstalled))
	fmt.Printf("  cfst 就绪:     %s\n", yesNo(res.CFSTInstalled))
	fmt.Printf("  conf 骨架:     %s\n", yesNo(res.ConfInit))
	fmt.Printf("  计划任务调度:  %s\n", yesNo(res.ScheduleInstalled))
	if len(res.Errors) > 0 {
		fmt.Println("  错误:")
		for _, e := range res.Errors {
			fmt.Printf("    - %s\n", e)
		}
	}
	if len(res.Warnings) > 0 {
		fmt.Println("  警告（不影响安装完成）:")
		for _, w := range res.Warnings {
			fmt.Printf("    - %s\n", w)
		}
	}
	fmt.Println()
	if !res.GlobalCommandInstalled {
		fmt.Printf("提示：便携模式未写系统 PATH；从 %s 目录直接运行 `cfopt` 即可使用。\n", dir)
	}
}

// yesNo 将布尔转为中文 已就绪/未完成。
func yesNo(b bool) string {
	if b {
		return "已就绪"
	}
	return "未完成"
}

// modeLabel 将安装模式转为中文标签。
func modeLabel(m install.InstallMode) string {
	if m == install.ModeSystem {
		return "系统级"
	}
	return "便携"
}
