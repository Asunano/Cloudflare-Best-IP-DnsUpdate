package cmd

import (
	"context"
	"runtime"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/cfst"
	"cfopt/internal/common"
)

// newCFSTCmd 构造 `cfopt cfst` 命令：管理 cfst 测速二进制（当前支持 fetch 子命令）。
func newCFSTCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "cfst",
		Short: "cfst 测速二进制管理（下载 XIU2/CloudflareSpeedTest release）",
	}
	cmd.AddCommand(newCFSTFetchCmd())
	return cmd
}

// newCFSTFetchCmd 构造 `cfopt cfst fetch` 子命令：从官方 release 下载并安装 cfst。
func newCFSTFetchCmd() *cobra.Command {
	var (
		repo       string
		dest       string
		timeout    time.Duration
		goos       string
		goarch     string
		mirror     string
		autoMirror bool
	)
	cmd := &cobra.Command{
		Use:   "fetch",
		Short: "下载并安装 cfst 二进制（SHA256 校验）",
		RunE: func(cmd *cobra.Command, args []string) error {
			opts := cfst.CFSTFetchOptions{
				Repo:       repo,
				DestDir:    dest,
				Timeout:    timeout,
				Goos:       goos,
				Goarch:     goarch,
				Mirror:     mirror,
				AutoMirror: autoMirror,
			}
			if opts.Goos == "" {
				opts.Goos = runtime.GOOS
			}
			if opts.Goarch == "" {
				opts.Goarch = runtime.GOARCH
			}
			path, err := cfst.Fetch(context.Background(), opts)
			if err != nil {
				return common.Wrap("cmd:cfst:fetch", err)
			}
			cmd.Printf("已下载并安装 cfst 到: %s\n", path)
			return nil
		},
	}
	cmd.Flags().StringVar(&repo, "repo", "", "GitHub 仓库 (owner/name)，默认 XIU2/CloudflareSpeedTest")
	cmd.Flags().StringVar(&dest, "dest", "", "安装目录（默认 ./assets/cfst）")
	cmd.Flags().DurationVar(&timeout, "timeout", 120*time.Second, "下载超时")
	cmd.Flags().StringVar(&goos, "os", "", "目标操作系统（默认当前 GOOS）")
	cmd.Flags().StringVar(&goarch, "arch", "", "目标架构（默认当前 GOARCH，仅支持 amd64/arm64）")
	cmd.Flags().StringVar(&mirror, "mirror", "", "镜像源 URL（优先从镜像下载 cfst，失败回退 GitHub）")
	cmd.Flags().BoolVar(&autoMirror, "auto-mirror", true, "智能镜像：按地区自动启用 gh-proxy 加速（中国地区默认开启）")
	return cmd
}
