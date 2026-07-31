package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// Version 由 go build -ldflags "-X cfopt/cmd.Version=..." 注入；默认占位值。
var Version = "dev"

// Commit 由 go build -ldflags "-X cfopt/cmd.Commit=..." 注入，记录构建时的 git commit。
var Commit = ""

// BuiltAt 由 go build -ldflags "-X cfopt/cmd.BuiltAt=..." 注入，记录构建时间（UTC）。
var BuiltAt = ""

// newVersionCmd 构造 `cfopt version` 命令。
func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "打印版本信息",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("cfopt %s\n", Version)
			if Commit != "" {
				fmt.Printf("commit: %s\n", Commit)
			}
			if BuiltAt != "" {
				fmt.Printf("built:  %s\n", BuiltAt)
			}
		},
	}
}
