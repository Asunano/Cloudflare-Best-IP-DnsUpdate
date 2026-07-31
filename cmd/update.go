package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"cfopt/internal/prompt"
	"cfopt/internal/update"
)

// newUpdateCmd 构造 `cfopt update` 命令：检查/执行自更新（从 GitHub release 拉取并替换二进制）。
//
// 退出码：
//   - 0：成功 / 已是最新
//   - 1：错误
//   - 2：有更新但需确认被跳过（--yes 未给）
func newUpdateCmd() *cobra.Command {
	var (
		check      bool
		yes        bool
		repo       string
		asset      string
		url        string
		timeout    time.Duration
		noVerify   bool
		rollback   bool
		mirror     string
		autoMirror bool
	)
	cmd := &cobra.Command{
		Use:   "update",
		Short: "自更新 cfopt（从 GitHub release 拉取并原子替换二进制）",
		RunE: func(cmd *cobra.Command, args []string) error {
			up := update.New(repo)
			if mirror != "" {
				up.SetMirror(mirror)
			}
			// 智能镜像：默认按地区自动启用 gh-proxy 加速（DownloadAndReplace 内按地区解析）。
			up.EnableAutoMirror = autoMirror
			currentBin, err := os.Executable()
			if err != nil {
				return fmt.Errorf("update: 获取当前二进制路径: %w", err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()

			// 回滚分支。
			if rollback {
				if err := update.Rollback(currentBin); err != nil {
					return fmt.Errorf("update: rollback: %w", err)
				}
				fmt.Println("已回滚到上一版本 (cfopt.old)")
				return nil
			}

			info, err := up.Check(ctx)
			if err != nil {
				return fmt.Errorf("update: 检查更新: %w", err)
			}
			newer, err := update.IsNewer(info.Version, Version)
			if err != nil {
				return fmt.Errorf("update: 版本比较: %w", err)
			}

			// --check：仅检查。有更新返回退出码 2（供脚本判断），否则 0。
			if check {
				if newer {
					fmt.Printf("发现新版本: v%s（当前 v%s）\n", info.Version, Version)
					printReleaseNotes(info.Notes)
					os.Exit(2)
				}
				fmt.Printf("已是最新版本: v%s\n", Version)
				return nil
			}

			if !newer {
				fmt.Printf("已是最新版本: v%s\n", Version)
				return nil
			}

			// 有更新但未确认 → 退出码 2。
			if !yes {
				fmt.Printf("发现新版本 v%s（当前 v%s）。使用 --yes 确认更新。\n", info.Version, Version)
				os.Exit(2)
			}

			opts := update.Options{
				Asset:    asset,
				URL:      url,
				NoVerify: noVerify,
				Timeout:  timeout,
			}
			if err := runUpdateGuarded(up, ctx, currentBin, info, opts); err != nil {
				return err
			}
			fmt.Printf("已更新到 v%s\n", info.Version)
			return nil
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "仅检查更新（不下载）")
	cmd.Flags().BoolVarP(&yes, "yes", "y", false, "确认执行更新")
	cmd.Flags().StringVar(&repo, "repo", "", "GitHub 仓库 (owner/name)，默认内置常量")
	cmd.Flags().StringVar(&asset, "asset", "", "指定资产名（默认按平台推断 cfopt-<goos>-<goarch>[.exe]）")
	cmd.Flags().StringVar(&url, "url", "", "调试：直接指定下载 URL")
	cmd.Flags().DurationVar(&timeout, "timeout", 120*time.Second, "下载超时")
	cmd.Flags().BoolVar(&noVerify, "no-verify", false, "跳过 SHA256 校验（不安全）")
	cmd.Flags().BoolVar(&rollback, "rollback", false, "回滚到上一版本 (cfopt.old)")
	cmd.Flags().StringVar(&mirror, "mirror", "", "镜像源 URL（优先从镜像下载，失败回退 GitHub）")
	cmd.Flags().BoolVar(&autoMirror, "auto-mirror", true, "智能镜像：按地区自动启用 gh-proxy 加速（中国地区默认开启）")
	return cmd
}

// printReleaseNotes 友好展示发布说明（去空白、限制行数，避免刷屏）。
func printReleaseNotes(notes string) {
	notes = strings.TrimSpace(notes)
	if notes == "" {
		return
	}
	fmt.Println("更新说明:")
	lines := strings.Split(notes, "\n")
	const maxLines = 15
	if len(lines) > maxLines {
		lines = append(lines[:maxLines], "...")
	}
	for _, l := range lines {
		fmt.Printf("  %s\n", strings.TrimSpace(l))
	}
}

// runCheckUpdate 主菜单「检查更新」：展示当前/最新版本与变更说明，并询问是否更新。
func runCheckUpdate() error {
	up := update.New("")
	up.EnableAutoMirror = true // 菜单更新路径默认启用智能镜像
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	info, err := up.Check(ctx)
	if err != nil {
		return fmt.Errorf("update: 检查更新: %w", err)
	}
	newer, err := update.IsNewer(info.Version, Version)
	if err != nil {
		return fmt.Errorf("update: 版本比较: %w", err)
	}
	if !newer {
		fmt.Printf("已是最新版本: v%s\n", Version)
		return nil
	}
	fmt.Printf("发现新版本 v%s（当前 v%s）\n", info.Version, Version)
	printReleaseNotes(info.Notes)
	if !prompt.Confirm("是否立即更新？", false) {
		return nil
	}
	currentBin, err := os.Executable()
	if err != nil {
		return fmt.Errorf("update: 获取当前二进制路径: %w", err)
	}
	opts := update.Options{Timeout: 60 * time.Second}
	if err := runUpdateGuarded(up, ctx, currentBin, info, opts); err != nil {
		return err
	}
	fmt.Printf("已更新到 v%s\n", info.Version)
	return nil
}

// runUpdateGuarded 经防更新循环保护执行自更新；对 ErrUpdateLoop 给出友好提示。
func runUpdateGuarded(up *update.Updater, ctx context.Context, currentBin string, info *update.ReleaseInfo, opts update.Options) error {
	err := update.RunGuarded(up, ctx, currentBin, info, opts)
	if err != nil {
		if errors.Is(err, update.ErrUpdateLoop) {
			return fmt.Errorf("update: 防更新循环保护已触发: %w", err)
		}
		return fmt.Errorf("update: 替换二进制: %w", err)
	}
	return nil
}
