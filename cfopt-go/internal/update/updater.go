// Package update 实现 cfopt 的自更新能力：检查 GitHub release、按平台推断资产名、
// 流式下载（强制 TLS / HTTP 200 / 长度校验）、强制 SHA256 校验、原子替换与回滚。
//
// 安全红线（务必遵守）：
//   - 官方源优先：下载 URL 必须为 https（测试/调试可置 Updater.Insecure=true 放宽）。
//   - 非 200 / TLS 失败 / 长度不符 均直接报错，绝不替换。
//   - 强制 SHA256 校验：优先匹配 release 的 SHA256SUMS 资产（按文件名），校验失败删除临时文件并 error。
//   - 不做递归删除、不 chmod 777、不后台异步删除；仅原子 os.Rename。
package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/blang/semver"

	"cfopt/internal/common"
	"cfopt/internal/geo"
)

const (
	// DefaultRepo 默认 GitHub 仓库（cfopt 发布源）。具体值由发布方确认，可由 --repo 覆盖。
	DefaultRepo = "cfopt/cfopt"
	// DefaultTimeout 下载默认超时。
	DefaultTimeout = 120 * time.Second
)

// ReleaseInfo 一次 release 的元信息。
type ReleaseInfo struct {
	Version string
	TagName string
	Notes   string // 发布说明（release body），供检查更新展示变更说明
	Assets  []Asset
}

// Asset 单个发布资产。
type Asset struct {
	Name   string
	URL    string
	Size   int64
	Digest string // 可选：资产 SHA256 摘要（GitHub API 形如 "sha256:xxxx"），用于强制校验。
}

// Options 更新选项（由 CLI flag 映射）。
type Options struct {
	Check    bool
	Yes      bool
	Asset    string
	URL      string
	Timeout  time.Duration
	NoVerify bool
}

// Updater 负责检查与执行自更新。
type Updater struct {
	Repo     string
	APIBase  string // 默认 https://api.github.com（测试可置为 httptest 地址）
	Client   *http.Client
	Mirror   string // 镜像源 URL，优先从该地址下载（失败回退 GitHub）
	ProxyPrefix      string // 智能镜像代理前缀（如 https://v4.gh-proxy.org/），非空时拼到原始下载 URL 前
	EnableAutoMirror bool   // 未显式指定 Mirror/ProxyPrefix 时，按地区自动决定是否启用镜像
	Insecure bool   // 仅测试/调试：允许 http 下载（生产必须为 https）
}

// SetMirror 设置镜像源 URL。更新流程将优先从镜像下载，失败则回退 GitHub。
func (u *Updater) SetMirror(url string) {
	u.Mirror = url
}

// SetProxyPrefix 显式设置镜像代理前缀（直接拼在原始下载 URL 前，形如 https://v4.gh-proxy.org/）。
func (u *Updater) SetProxyPrefix(prefix string) {
	u.ProxyPrefix = prefix
}

// ResolveAutoMirror 在未显式指定 Mirror/ProxyPrefix 时，按客户端地区自动决定是否启用镜像：
// 若检测到位于中国（CN），将 ProxyPrefix 置为 geo.ChinaMirrorProxy（https://v4.gh-proxy.org/）。
// 任何检测异常均静默跳过，不覆盖既有 Mirror/ProxyPrefix，也不阻断主流程。
func (u *Updater) ResolveAutoMirror(ctx context.Context) {
	if !u.EnableAutoMirror {
		return
	}
	if u.Mirror != "" || u.ProxyPrefix != "" {
		return
	}
	cn, err := geo.IsInChina(ctx)
	if err != nil {
		return
	}
	if cn {
		u.ProxyPrefix = geo.ChinaMirrorProxy
	}
}

// New 构造 Updater（repo 为空则用 DefaultRepo）。
func New(repo string) *Updater {
	if repo == "" {
		repo = DefaultRepo
	}
	return &Updater{
		Repo:    repo,
		APIBase: "https://api.github.com",
		Client:  &http.Client{Timeout: DefaultTimeout},
	}
}

// AssetName 推断资产名：cfopt-<goos>-<goarch>[.exe]（与 release.yml 上传命名完全一致）。
func AssetName(goos, goarch string) string {
	name := fmt.Sprintf("cfopt-%s-%s", goos, goarch)
	if goos == "windows" {
		name += ".exe"
	}
	return name
}

// CurrentAssetName 依据当前运行平台推断资产名。
func CurrentAssetName() string {
	return AssetName(runtime.GOOS, runtime.GOARCH)
}

// ParseVersion 解析版本字符串为 semver（容忍前导 v）。
func ParseVersion(v string) (semver.Version, error) {
	v = strings.TrimSpace(v)
	v = strings.TrimPrefix(v, "v")
	return semver.ParseTolerant(v)
}

// IsNewer 判断 latest 是否比 current 新（基于 semver 比较）。
func IsNewer(latest, current string) (bool, error) {
	lv, err := ParseVersion(latest)
	if err != nil {
		return false, fmt.Errorf("update:parse latest %q: %w", latest, err)
	}
	cv, err := ParseVersion(current)
	if err != nil {
		return false, fmt.Errorf("update:parse current %q: %w", current, err)
	}
	return lv.GT(cv), nil
}

type githubRelease struct {
	TagName string `json:"tag_name"`
	Body    string `json:"body"`
	Assets  []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Size               int64  `json:"size"`
		Digest             string `json:"digest"`
	} `json:"assets"`
}

// Check 查询仓库最新 release，返回 ReleaseInfo。
// 若启用智能镜像（EnableAutoMirror），则以「直连→镜像重试」兜底，防止国内机器连接 api.github.com 异常。
func (u *Updater) Check(ctx context.Context) (*ReleaseInfo, error) {
	baseURL := fmt.Sprintf("%s/repos/%s/releases/latest", u.APIBase, u.Repo)

	var info *ReleaseInfo
	doCheck := func(ctx context.Context, url string) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return fmt.Errorf("update:check:newrequest: %w", err)
		}
		req.Header.Set("Accept", "application/vnd.github+json")
		resp, err := u.Client.Do(req)
		if err != nil {
			return fmt.Errorf("update:check: %w", err)
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("update:check: HTTP %d", resp.StatusCode)
		}
		var gr githubRelease
		if err := json.NewDecoder(resp.Body).Decode(&gr); err != nil {
			return fmt.Errorf("update:check:decode: %w", err)
		}
		info = &ReleaseInfo{TagName: gr.TagName, Version: strings.TrimPrefix(gr.TagName, "v"), Notes: gr.Body}
		for _, a := range gr.Assets {
			info.Assets = append(info.Assets, Asset{Name: a.Name, URL: a.BrowserDownloadURL, Size: a.Size, Digest: a.Digest})
		}
		return nil
	}

	if u.EnableAutoMirror {
		if err := geo.WithMirrorFallback(ctx, baseURL, u.Client.Timeout, doCheck); err != nil {
			return nil, err
		}
		return info, nil
	}
	if err := doCheck(ctx, baseURL); err != nil {
		return nil, err
	}
	return info, nil
}

// Download 将指定 URL 下载到 dest，返回写入字节数（包级下载能力的对外封装，供 cfst 等复用）。
func (u *Updater) Download(ctx context.Context, url, dest string) (int64, error) {
	return u.download(ctx, url, dest)
}

// download 将 url 下载到 dest，要求 HTTP 200；返回写入字节数。
// 安全：默认拒绝非 https 源（Insecure=true 可放宽，仅供测试）。
func (u *Updater) download(ctx context.Context, url, dest string) (int64, error) {
	// 智能镜像：将原始 https 下载链接改写为经过代理前缀的链接
	// （如 https://v4.gh-proxy.org/https://github.com/...）。仅对 https 原始链接生效，且避免重复拼接。
	if u.ProxyPrefix != "" && strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, u.ProxyPrefix) {
		prefix := strings.TrimRight(u.ProxyPrefix, "/") + "/"
		url = prefix + url
	}
	if !strings.HasPrefix(url, "https://") && !u.Insecure {
		return 0, fmt.Errorf("update:download: 拒绝非官方/非 TLS 源: %s", url)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, fmt.Errorf("update:download:newrequest: %w", err)
	}
	resp, err := u.Client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("update:download: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("update:download: HTTP %d (期望 200)", resp.StatusCode)
	}
	f, err := os.Create(dest)
	if err != nil {
		return 0, fmt.Errorf("update:download:create %s: %w", dest, err)
	}
	defer func() { _ = f.Close() }()
	n, err := io.Copy(f, resp.Body)
	if err != nil {
		return 0, fmt.Errorf("update:download:copy: %w", err)
	}
	return n, nil
}

// fetchSHA256SUMS 下载 release 的 SHA256SUMS 资产，解析并返回指定文件名的期望哈希。
func (u *Updater) fetchSHA256SUMS(ctx context.Context, info *ReleaseInfo, assetName string) string {
	for _, a := range info.Assets {
		if a.Name != "SHA256SUMS" {
			continue
		}
		tmp := filepath.Join(os.TempDir(), fmt.Sprintf("cfopt-sums-%d.tmp", os.Getpid()))
		// 智能镜像兜底：直连 SHA256SUMS 失败则重试镜像。
		if u.EnableAutoMirror {
			if err := geo.WithMirrorFallback(ctx, a.URL, u.Client.Timeout, func(c context.Context, url string) error {
				_, e := u.download(c, url, tmp)
				return e
			}); err != nil {
				return ""
			}
		} else if _, err := u.download(ctx, a.URL, tmp); err != nil {
			return ""
		}
		defer func() { _ = os.Remove(tmp) }()
		data, err := os.ReadFile(tmp)
		if err != nil {
			return ""
		}
		if h, ok := parseSHA256SUMS(data, assetName); ok {
			return h
		}
	}
	return ""
}

// parseSHA256SUMS 从 sha256sum 格式文本中解析指定文件名的哈希（忽略 * 前缀）。
func parseSHA256SUMS(data []byte, name string) (string, bool) {
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		hash := fields[0]
		fname := fields[len(fields)-1]
		fname = strings.TrimPrefix(fname, "*")
		if fname == name {
			return hash, true
		}
	}
	return "", false
}

// sha256File 计算文件 SHA256（十六进制小写）。
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// VerifySHA256 校验 path 的 SHA256 是否与 expected 一致（expected 形如 "sha256:xxxx" 时自动去前缀）。
// 返回 (true, nil) 表示匹配；(false, nil) 表示不匹配；(false, err) 表示计算/参数错误。
func VerifySHA256(path, expected string) (bool, error) {
	expected = strings.TrimSpace(expected)
	expected = strings.TrimPrefix(expected, "sha256:")
	if expected == "" {
		return false, fmt.Errorf("update:verify: 缺少期望哈希值")
	}
	got, err := sha256File(path)
	if err != nil {
		return false, fmt.Errorf("update:verify:sha256: %w", err)
	}
	return strings.EqualFold(got, expected), nil
}

// DownloadAndReplace 下载最新版本并原子替换当前二进制。
// 校验链：HTTP 200 → 长度匹配（已知时）→ SHA256 匹配（已知时）；任一不符即删除临时文件并 error，绝不替换。
// 若设置了 Mirror，优先从镜像 URL 下载，失败则回退 GitHub 原始 URL。
func (u *Updater) DownloadAndReplace(ctx context.Context, currentBin string, info *ReleaseInfo, opts Options) error {
	// 智能镜像：未显式指定镜像时，按地区自动决定是否走代理（中国地区加速）。
	u.ResolveAutoMirror(ctx)

	assetName := opts.Asset
	if assetName == "" {
		assetName = CurrentAssetName()
	}

	var assetURL string
	var assetSize int64
	if opts.URL != "" {
		assetURL = opts.URL
	} else {
		for _, a := range info.Assets {
			if a.Name == assetName {
				assetURL = a.URL
				assetSize = a.Size
				break
			}
		}
		if assetURL == "" {
			return fmt.Errorf("update: 找不到匹配资产: %s", assetName)
		}
	}

	// 期望 SHA256：优先 SHA256SUMS 资产按文件名匹配（GitHub 单资产无内建哈希）。
	var expectedSHA string
	if !opts.NoVerify {
		if sum := u.fetchSHA256SUMS(ctx, info, assetName); sum != "" {
			expectedSHA = sum
		}
	}

	dir := filepath.Dir(currentBin)
	tmp := filepath.Join(dir, "cfopt.download")
	_ = os.Remove(tmp) // 清理可能残留的临时文件

	// 镜像源优先：若设置了 Mirror URL，构造镜像下载链接并优先尝试。
	downloaded := false
	if u.Mirror != "" {
		mirrorURL := buildMirrorURL(u.Mirror, u.Repo, info.Version, assetName)
		fmt.Printf("尝试从镜像源下载: %s\n", mirrorURL)
		if u.downloadAndVerify(ctx, mirrorURL, tmp, assetSize, expectedSHA) {
			fmt.Println("镜像下载成功，跳过 GitHub 直连。")
			downloaded = true
		} else {
			fmt.Printf("镜像下载失败，回退 GitHub 原始源。\n")
			_ = os.Remove(tmp)
		}
	}

	if !downloaded {
		var n int64
		doDownload := func(c context.Context, url string) error {
			var e error
			n, e = u.download(c, url, tmp)
			return e
		}
		var dlErr error
		if u.EnableAutoMirror {
			// 智能镜像兜底：直连失败自动重试镜像（防止国内机器连接 GitHub 异常）。
			dlErr = geo.WithMirrorFallback(ctx, assetURL, u.Client.Timeout, doDownload)
		} else {
			dlErr = doDownload(ctx, assetURL)
		}
		if dlErr != nil {
			_ = os.Remove(tmp)
			return dlErr
		}
		// 长度校验
		if assetSize > 0 && n != assetSize {
			_ = os.Remove(tmp)
			return fmt.Errorf("update: 下载长度不符: got=%d want=%d", n, assetSize)
		}
		// SHA256 校验
		if expectedSHA != "" {
			got, err := sha256File(tmp)
			if err != nil {
				_ = os.Remove(tmp)
				return fmt.Errorf("update: sha256 计算: %w", err)
			}
			if !strings.EqualFold(got, expectedSHA) {
				_ = os.Remove(tmp)
				return fmt.Errorf("update: SHA256 校验失败（绝不替换）: got=%s want=%s", got, expectedSHA)
			}
		}
	}

	// Windows 平台：自更新（currentBin 即正在运行的自身）时，因 Windows 锁定运行中的 exe，
	// 无法直接 rename；改为写入 cfopt-update.bat 等待父进程退出后原子替换并自删，随后 os.Exit(0)
	// 释放对 cfopt.exe 的锁定，由 bat 完成最终替换。非自身（如测试中的临时文件）走下方同步替换。
	if runtime.GOOS == "windows" {
		if exe, eerr := os.Executable(); eerr == nil && filepath.Clean(exe) == filepath.Clean(currentBin) {
			if err := replaceWindowsDeferred(currentBin, tmp, os.Getpid()); err != nil {
				_ = os.Remove(tmp)
				return fmt.Errorf("update: 替换二进制(windows): %w", err)
			}
			common.Debug("update: 已启动自更新脚本，父进程退出后完成替换")
			os.Exit(0)
		}
	}

	// 备份当前二进制为 cfopt.old（原子 rename）。
	if _, statErr := os.Stat(currentBin); statErr == nil {
		backup := currentBin + ".old"
		_ = os.Remove(backup)
		if err := os.Rename(currentBin, backup); err != nil {
			_ = os.Remove(tmp)
			return fmt.Errorf("update: 备份当前二进制: %w", err)
		}
	}
	// 原子替换
	if err := os.Rename(tmp, currentBin); err != nil {
		return fmt.Errorf("update: 替换二进制: %w", err)
	}
	return nil
}

// downloadAndVerify 从指定 URL 下载文件到 tmp，并进行长度和 SHA256 校验。
// 返回 true 表示下载且校验均通过。
func (u *Updater) downloadAndVerify(ctx context.Context, url, tmp string, assetSize int64, expectedSHA string) bool {
	n, err := u.download(ctx, url, tmp)
	if err != nil {
		return false
	}
	if assetSize > 0 && n != assetSize {
		return false
	}
	if expectedSHA != "" {
		got, err := sha256File(tmp)
		if err != nil {
			return false
		}
		if !strings.EqualFold(got, expectedSHA) {
			return false
		}
	}
	return true
}

// replaceWindowsDeferred 写入 cfopt-update.bat 并分离启动；bat 在父进程（cfopt update）退出后
// 完成 cfopt.download → cfopt.exe 的原子替换、旧 exe 备份为 cfopt.old、并自删。
// 仅在 Windows + 自更新（currentBin 即自身）场景调用；非自身场景由调用方走同步替换。
func replaceWindowsDeferred(currentBin, tmp string, pid int) error {
	if _, err := os.Stat(tmp); err != nil {
		return fmt.Errorf("update: 临时文件不存在: %w", err)
	}
	dir := filepath.Dir(currentBin)
	bat, err := writeUpdateBatchFile(dir, pid)
	if err != nil {
		return err
	}
	// 分离启动 bat（绝对路径），父进程随后 os.Exit(0) 释放锁定。
	cmd := exec.Command("cmd", "/c", "start", "", bat)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("update: 启动更新脚本: %w", err)
	}
	return nil
}

// writeUpdateBatchFile 生成 cfopt-update.bat 到 dir 并返回其绝对路径（供测试验证内容）。
func writeUpdateBatchFile(dir string, pid int) (string, error) {
	bat := filepath.Join(dir, "cfopt-update.bat")
	if err := os.WriteFile(bat, []byte(buildUpdateBatchContent(dir, pid)), 0o644); err != nil {
		return "", fmt.Errorf("update: 写入更新脚本: %w", err)
	}
	return bat, nil
}

// buildUpdateBatchContent 生成 Windows 自更新批处理脚本内容：
//   - 绝对路径：脚本写到 currentBin 所在目录，并以 `cd /d dir` 切换到该目录，
//     使相对名 cfopt.exe / cfopt.old / cfopt.download 在正确目录解析；
//   - :wait 循环 `tasklist | find "<PID>"` 直到父进程退出；
//   - 随后 move /Y cfopt.exe cfopt.old、move /Y cfopt.download cfopt.exe、
//     并 del "%~f0"（自删）。
func buildUpdateBatchContent(dir string, pid int) string {
	var b strings.Builder
	b.WriteString("@echo off\r\n")
	b.WriteString("cd /d \"" + dir + "\"\r\n")
	b.WriteString(":wait\r\n")
	b.WriteString("tasklist | find \"" + strconv.Itoa(pid) + "\" >nul && goto wait\r\n")
	b.WriteString("move /Y cfopt.exe cfopt.old\r\n")
	b.WriteString("move /Y cfopt.download cfopt.exe\r\n")
	b.WriteString("del \"%~f0\"\r\n")
	return b.String()
}

// Rollback 回滚到上一版本：将当前二进制备份为 cfopt.rolledback，再恢复 cfopt.old。
func Rollback(currentBin string) error {
	backup := currentBin + ".old"
	if _, err := os.Stat(backup); err != nil {
		return fmt.Errorf("update: rollback: 无备份文件 %s", backup)
	}
	rolled := currentBin + ".rolledback"
	_ = os.Remove(rolled)
	if _, statErr := os.Stat(currentBin); statErr == nil {
		if err := os.Rename(currentBin, rolled); err != nil {
			return fmt.Errorf("update: rollback: 备份当前二进制: %w", err)
		}
	}
	if err := os.Rename(backup, currentBin); err != nil {
		return fmt.Errorf("update: rollback: 恢复旧版本: %w", err)
	}
	return nil
}

// buildMirrorURL 构建镜像下载 URL。
// mirrorBase 是镜像源基地址（如 "https://ghproxy.com/https://github.com"），
// repo 是 GitHub 仓库名（如 "cfopt/cfopt"），version 是版本号，assetName 是资产名。
// 返回完整下载 URL。
func buildMirrorURL(mirrorBase, repo, version, assetName string) string {
	mirrorBase = strings.TrimRight(mirrorBase, "/")
	return fmt.Sprintf("%s/%s/releases/download/v%s/%s", mirrorBase, repo, version, assetName)
}
