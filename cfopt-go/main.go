// Package main 是 cfopt Go 重写版的 CLI 入口。
// 所有业务逻辑在 internal/ 与 cmd/ 中，main 仅负责拉起 cobra 命令树。
package main

import "cfopt/cmd"

func main() {
	cmd.Execute()
}
