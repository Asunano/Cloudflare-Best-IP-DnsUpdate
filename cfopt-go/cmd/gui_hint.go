package cmd

import "fmt"

// printWindowsGuiHint 打印 Windows 下推荐 GUI 的提示（纯 CLI 文案，不改 IPC/GUI 契约）。
// 调用方应自行用 runtime.GOOS == "windows" 门控（install 与 menu 复用此函数）。
func printWindowsGuiHint() {
	fmt.Println("💡 提示：在 Windows 上，推荐直接使用图形界面（GUI）版本完成安装与部署，操作更直观、无需命令行。" +
		"GUI 桌面程序可在本项目 Release 页获取（基于 Tauri，自动封装本命令行核心）。您当前使用的是命令行（CLI）模式。")
}
