// Package cfst 提供 cfst（XIU2/CloudflareSpeedTest）测速二进制的安装/更新能力：
// 从官方 GitHub release 下载对应平台的压缩包，按 asset.digest 做强制 SHA256 校验，
// 解压后重命名为 assets/cfst/cfst[.exe] 落盘。复用 internal/update 的下载/校验能力，不重复实现网络与哈希。
package cfst

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/update"
)

const (
	// DefaultCFSTRepo cfst 官方仓库。
	DefaultCFSTRepo = "XIU2/CloudflareSpeedTest"
	// DefaultCFSTDestDir 默认安装目录（与 cfst 测速探测目录一致）。
	DefaultCFSTDestDir = "./assets/cfst"
	// cfstReleaseBase cfst 官方 release 页面（友好安装引导用）。
	cfstReleaseBase = "https://github.com/XIU2/CloudflareSpeedTest/releases"
)

// CFSTFetchOptions cfst 二进制下载选项。
type CFSTFetchOptions struct {
	Repo     string        // GitHub 仓库 owner/name，默认 XIU2/CloudflareSpeedTest
	Goos     string        // 目标操作系统，默认 runtime.GOOS
	Goarch   string        // 目标架构，默认 runtime.GOARCH（仅支持 amd64/arm64）
	DestDir  string        // 安装目录，默认 ./assets/cfst
	Timeout  time.Duration // 下载超时，默认 update.DefaultTimeout
	Insecure bool          // 仅测试/调试：允许 http 下载
	APIBase  string        // 可选：覆盖 update.Updater 的 API 基地址（测试注入 httptest）
	Mirror   string        // 镜像源 URL，优先从该地址下载（失败回退 GitHub）
}

// Fetch 从官方 release 下载并安装 cfst 二进制，返回安装后的绝对路径。
//
// 流程：update.New(repo).Check 取 latest → 匹配 cfst_<goos>_<goarch>.{zip|tar.gz}（排除 _old 变体）
// → Updater.Download 下载到临时文件 → 取 asset.Digest 经 update.VerifySHA256 校验（失败不落盘并 error）
// → 按平台用 archive/zip（Windows/Darwin）或 archive/tar+compress/gzip（Linux）解压
// → 取包内 cfst / cfst.exe 重命名为 assets/cfst/cfst[.exe] 落盘。
func Fetch(ctx context.Context, opts CFSTFetchOptions) (string, error) {
	if opts.Repo == "" {
		opts.Repo = DefaultCFSTRepo
	}
	if opts.Goos == "" {
		opts.Goos = runtime.GOOS
	}
	if opts.Goarch == "" {
		opts.Goarch = runtime.GOARCH
	}
	if opts.DestDir == "" {
		opts.DestDir = DefaultCFSTDestDir
	}
	if opts.Timeout == 0 {
		opts.Timeout = update.DefaultTimeout
	}
	switch opts.Goarch {
	case "amd64", "arm64":
	default:
		return "", common.New("cfst:fetch", fmt.Sprintf("不支持的架构: %s（仅支持 amd64/arm64）", opts.Goarch))
	}

	up := update.New(opts.Repo)
	if opts.APIBase != "" {
		up.APIBase = opts.APIBase
	}
	if opts.Mirror != "" {
		up.SetMirror(opts.Mirror)
	}
	up.Insecure = opts.Insecure
	up.Client.Timeout = opts.Timeout

	info, err := up.Check(ctx)
	if err != nil {
		return "", common.Wrap("cfst:fetch:check", err)
	}

	// 匹配资产：cfst_<goos>_<goarch>.{zip|tar.gz}，排除 _old 后缀变体。
	var asset update.Asset
	found := false
	for _, a := range info.Assets {
		base := strings.TrimSuffix(a.Name, filepath.Ext(a.Name))
		if strings.HasSuffix(base, "_old") {
			continue // 排除 _old 变体
		}
		if matchCFSTAsset(a.Name, opts.Goos, opts.Goarch) {
			asset = a
			found = true
			break
		}
	}
	if !found {
		return "", common.New("cfst:fetch", fmt.Sprintf(
			"未找到匹配资产 cfst_%s_%s（zip/tar.gz）\n可手动从 %s 下载后放到 %s",
			opts.Goos, opts.Goarch, cfstReleaseBase, opts.DestDir))
	}

	// 下载到临时文件。
	tmp, err := os.CreateTemp("", "cfst-fetch-*")
	if err != nil {
		return "", common.Wrap("cfst:fetch:tmp", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := up.Download(ctx, asset.URL, tmpName); err != nil {
		return "", common.Wrap("cfst:fetch:download", err)
	}

	// 强制 SHA256 校验（asset.Digest 形如 sha256:xxxx）；失败不落盘。
	if asset.Digest != "" {
		ok, err := update.VerifySHA256(tmpName, asset.Digest)
		if err != nil {
			return "", common.Wrap("cfst:fetch:verify", err)
		}
		if !ok {
			return "", common.New("cfst:fetch", fmt.Sprintf(
				"SHA256 校验失败（绝不落盘），期望 %s", asset.Digest))
		}
	} else {
		common.Warn("cfst:fetch: 资产未携带 digest，跳过 SHA256 校验（建议核实来源）")
	}

	// 全量解压到 DestDir（保持压缩包内所有文件：cfst.exe + IP 数据文件等）。
	if err := os.MkdirAll(opts.DestDir, 0o755); err != nil {
		return "", common.Wrap("cfst:fetch:mkdir", err)
	}
	if err := extractArchiveToDir(tmpName, opts.DestDir, opts.Goos); err != nil {
		return "", common.Wrap("cfst:fetch:extract", err)
	}

	// 确认 cfst 二进制安装成功，返回其路径。
	binName := "cfst"
	if opts.Goos == "windows" {
		binName = "cfst.exe"
	}
	dst := filepath.Join(opts.DestDir, binName)
	if _, err := os.Stat(dst); err != nil {
		return "", common.Wrap("cfst:fetch:install", fmt.Errorf("解压后未找到 %s", dst))
	}
	// 非 Windows 确保可执行权限。
	if opts.Goos != "windows" {
		_ = os.Chmod(dst, 0o755)
	}
	common.Info("cfst:fetch: 安装完成", "path", dst, "dir", opts.DestDir)
	return dst, nil
}

// matchCFSTAsset 判断资产名是否匹配 cfst_<goos>_<goarch>.{zip|tar.gz}。
func matchCFSTAsset(name, goos, goarch string) bool {
	prefix := fmt.Sprintf("cfst_%s_%s.", goos, goarch)
	if !strings.HasPrefix(name, prefix) {
		return false
	}
	return strings.HasSuffix(name, ".zip") || strings.HasSuffix(name, ".tar.gz")
}

// extractArchiveToDir 将压缩包（zip/tar.gz）所有文件解压到 destDir。
// Linux 用 tar.gz，其他平台（Windows/Darwin）用 zip。
func extractArchiveToDir(archivePath, destDir, goos string) error {
	if goos == "linux" {
		return extractTarGzToDir(archivePath, destDir)
	}
	return extractZipToDir(archivePath, destDir)
}

// extractZipToDir 将 zip 包所有文件解压到 destDir（保持文件名原样，仅取 base name 避免路径穿越）。
func extractZipToDir(archivePath, destDir string) error {
	r, err := zip.OpenReader(archivePath)
	if err != nil {
		return common.Wrap("cfst:extract:zip:open", err)
	}
	defer func() { _ = r.Close() }()
	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		dest := filepath.Join(destDir, filepath.Base(f.Name))
		rc, err := f.Open()
		if err != nil {
			return common.Wrap("cfst:extract:zip:openentry", err)
		}
		data, err := io.ReadAll(rc)
		_ = rc.Close()
		if err != nil {
			return common.Wrap("cfst:extract:zip:read", err)
		}
		perm := f.Mode()
		if perm == 0 {
			perm = 0o644
		}
		if err := os.WriteFile(dest, data, perm); err != nil {
			return common.Wrap("cfst:extract:zip:write", err)
		}
	}
	return nil
}

// extractTarGzToDir 将 tar.gz 包所有文件解压到 destDir（保持文件名原样，仅取 base name）。
func extractTarGzToDir(archivePath, destDir string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return common.Wrap("cfst:extract:tar:open", err)
	}
	defer func() { _ = f.Close() }()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return common.Wrap("cfst:extract:tar:gzip", err)
	}
	defer func() { _ = gz.Close() }()
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return common.Wrap("cfst:extract:tar:next", err)
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		dest := filepath.Join(destDir, filepath.Base(hdr.Name))
		data, err := io.ReadAll(tr)
		if err != nil {
			return common.Wrap("cfst:extract:tar:read", err)
		}
		perm := os.FileMode(hdr.Mode)
		if perm == 0 {
			perm = 0o644
		}
		if err := os.WriteFile(dest, data, perm); err != nil {
			return common.Wrap("cfst:extract:tar:write", err)
		}
	}
	return nil
}
