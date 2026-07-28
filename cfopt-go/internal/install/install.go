// Package install 实现 cfopt 的自安置（复制自身二进制到目标目录）、全局命令安装
// （Windows 写用户级 PATH / 其他平台软链）、conf 骨架生成、cfst 二进制就绪与轻量网络体检。
//
// 设计原则：
//   - 幂等：已自安置/已存在配置/已装全局命令则跳过对应步骤，不破坏已有用户配置。
//   - 跨平台：Windows 用 PowerShell（[Environment]::SetEnvironmentVariable）写用户 PATH；其他用 os.Symlink。
//     严禁任何 bash 专属语法（由 Go os/exec 生成跨平台命令）。
//   - 路径守卫：禁止将自身安置到 /tmp|/dev|/proc|/sys 等危险目录，禁止路径中包含 ".."。
//   - 不触碰 IPC / Tauri GUI；调度安装由 cmd 层调用 runSchedule 完成（避免引入 cmd 依赖造成循环引用）。
//
// 本次增量引入「便携（portable）/ 系统级（system）」二态：
//   - 便携模式：二进制与配置同目录落盘，跳过全局命令与同目录自复制，删目录即干净退出。
//   - 系统级模式：保持 Phase B 旧行为（自安置 + 写 PATH/软链 + 可选调度）。
//
// 二态分支内聚在 internal/install，调度仅由 cmd 层在系统级时调用。
package install

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"cfopt/internal/cfst"
	"cfopt/internal/common"
	"cfopt/internal/config"
)

// InstallMode 安装/卸载模式：portable 便携 / system 系统级。
type InstallMode string

const (
	ModePortable InstallMode = "portable" // 便携：二进制与配置同目录，删目录即干净退出
	ModeSystem   InstallMode = "system"   // 系统级：自安置到 LOCALAPPDATA/系统目录 + 写全局命令
)

// InstallOptions 安装选项（取代旧 RunInstall(ctx, dir, cfgDir, withSchedule) 四参签名）。
type InstallOptions struct {
	Mode         InstallMode // portable | system（必填）
	Dir          string      // 二进制与资源安置目录（便携=--dir|Dir(Exe)；系统=defaultInstallDir()）
	CfgDir       string      // 配置目录（便携=Dir/conf；系统=global --config-dir 默认 "conf"）
	WithSchedule bool        // 仅 system 模式有意义；portable 由 cmd 层强制忽略
}

// InstallResult 安装结果汇总。
type InstallResult struct {
	Mode                   InstallMode // 本次安装模式
	SelfPlaced             bool        // 二进制已自安置到目标目录
	GlobalCommandInstalled bool        // 全局命令已安装（PATH/软链）；便携模式恒 false
	CFSTInstalled          bool        // cfst 已下载安装（落 Dir/assets/cfst）
	ConfInit               bool        // conf 骨架已生成
	ScheduleInstalled      bool        // 调度已注册（实际由 cmd 层 runSchedule 完成，此处记录意图）
	Warnings               []string    // 非致命告警（如网络体检失败、cfst 下载失败）
	Errors                 []string    // 致命错误
}

// UninstallOptions 卸载选项。
type UninstallOptions struct {
	Mode        InstallMode // portable | system
	Dir         string      // 便携=待删可移植目录；系统=defaultInstallDir()
	CfgDir      string      // 配置目录（便携忽略；系统=RemoveData 清理目标）
	RemoveData  bool        // 全清（含 conf/数据）；便携恒 true；系统默认 false（保留配置）
	SkipConfirm bool        // --force；确认逻辑由 cmd 层在调用前完成，install 包不交互
}

// UninstallResult 卸载结果（best-effort：列出成功与失败项）。
type UninstallResult struct {
	Mode     InstallMode // 本次卸载模式
	Removed  []string    // 成功移除的项描述（如 "目录 T"、"全局命令 PATH"）
	Failed   []string    // 移除失败的项（如 "运行中 cfopt.exe 被锁定，请退出后手动删除"）
	Warnings []string
}

// validateInstallDir 路径守卫：禁止危险目录（/tmp|/dev|/proc|/sys）与 ".."。
// 统一用正斜杠比较，兼容 Windows 反斜杠路径。
func validateInstallDir(dir string) error {
	if strings.Contains(dir, "..") {
		return fmt.Errorf("install: 安装目录禁止包含 '..': %s", dir)
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return common.Wrap("install:abspath", err)
	}
	absNorm := filepath.ToSlash(abs)
	forbidden := []string{"/tmp", "/dev", "/proc", "/sys"}
	for _, bad := range forbidden {
		if absNorm == bad || strings.HasPrefix(absNorm, bad+"/") || strings.Contains(absNorm, bad+"/") {
			return fmt.Errorf("install: 安装目录非法（禁止 %s）: %s", bad, abs)
		}
	}
	return nil
}

// SelfPlace 将 srcExe 复制到 dir 下（文件名 cfopt[.exe]）。已存在且大小一致则跳过（幂等）。
// 返回目标路径。
func SelfPlace(srcExe, dir string) (string, error) {
	if err := validateInstallDir(dir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", common.Wrap("install:mkdirdir", err)
	}
	name := "cfopt"
	if runtime.GOOS == "windows" {
		name = "cfopt.exe"
	}
	dst := filepath.Join(dir, name)

	srcInfo, err := os.Stat(srcExe)
	if err != nil {
		return "", common.Wrap("install:stat-src", err)
	}
	if dstInfo, err := os.Stat(dst); err == nil {
		// 已存在：大小一致视为同一版本，跳过复制（幂等）。
		if dstInfo.Size() == srcInfo.Size() {
			return dst, nil
		}
	}
	if err := copyFile(srcExe, dst); err != nil {
		return "", common.Wrap("install:selfplace", err)
	}
	// 非 Windows 设置可执行位。
	if runtime.GOOS != "windows" {
		_ = os.Chmod(dst, 0o755)
	}
	return dst, nil
}

// GlobalCommandInstaller 全局命令安装器（可被测试替换为 no-op，避免副作用）。
// 默认实现为 SetupGlobalCommand。
var GlobalCommandInstaller = SetupGlobalCommand

// GlobalCommandRemover 全局命令移除器（可被测试替换为 no-op，避免副作用）。
// 默认实现为 RemoveGlobalCommand。
var GlobalCommandRemover = RemoveGlobalCommand

// SetupGlobalCommand 安装全局命令（跨平台分支）。
// Windows：写用户级 PATH（PowerShell）。其他：/usr/local/bin/cfopt 软链。
func SetupGlobalCommand(dir string, goos string) error {
	if goos == "windows" {
		return setupGlobalCommandWindows(dir)
	}
	return setupGlobalCommandSymlink(dir, goos)
}

// setupGlobalCommandSymlink 在 /usr/local/bin/cfopt 创建软链指向自安置二进制（幂等）。
func setupGlobalCommandSymlink(dir, goos string) error {
	name := "cfopt"
	if goos == "windows" {
		name = "cfopt.exe"
	}
	bin := filepath.Join(dir, name)
	link := filepath.Join("/usr/local/bin", name)
	if _, err := os.Lstat(link); err == nil {
		// 已存在：若指向同一二进制则跳过。
		if t, e := os.Readlink(link); e == nil && filepath.Clean(t) == filepath.Clean(bin) {
			return nil
		}
		_ = os.Remove(link)
	}
	if err := os.MkdirAll("/usr/local/bin", 0o755); err != nil {
		return common.Wrap("install:symlink:mkdir", err)
	}
	if err := os.Symlink(bin, link); err != nil {
		return common.Wrap("install:symlink", err)
	}
	return nil
}

// setupGlobalCommandWindows 通过 PowerShell 将 dir 追加进用户级 PATH（幂等：已含则跳过）。
// 使用环境变量 CFOPT_INSTALL_DIR 传递路径，避免命令行引号转义问题（Windows 路径常含空格）。
func setupGlobalCommandWindows(dir string) error {
	script := `$d=$env:CFOPT_INSTALL_DIR;` +
		`$p=[Environment]::GetEnvironmentVariable('Path','User');` +
		`if(($p -split ';') -contains $d){Write-Output 'exists'}else{` +
		`[Environment]::SetEnvironmentVariable('Path',($p.TrimEnd(';')+';'+$d),'User');Write-Output 'added'}`
	cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass", "-Command", script)
	cmd.Env = append(os.Environ(), "CFOPT_INSTALL_DIR="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return common.Wrap("install:win-path:"+strings.TrimSpace(string(out)), err)
	}
	return nil
}

// ProvisionConf 生成 conf 目录骨架与默认模板（global/cf-ip/cf-dns/dnspod），幂等（仅写缺失文件）。
// 注意：cfgDir 本身即配置目录，多域名 conf 直接落在 cfgDir/cf-dns 与 cfgDir/dnspod（loader 扫描路径）。
func ProvisionConf(cfgDir string) error {
	for _, sub := range []string{"cf-dns", "dnspod", "assets/data"} {
		if err := os.MkdirAll(filepath.Join(cfgDir, sub), 0o755); err != nil {
			return common.Wrap("install:mkdir:"+sub, err)
		}
	}
	if err := config.WriteDefaults(cfgDir); err != nil {
		return common.Wrap("install:write-defaults", err)
	}
	return nil
}

// ensureCFST 确保 cfst 二进制就绪：已存在则跳过（幂等），否则触发 cfst.Fetch 下载并 SHA256 校验。
func ensureCFST(ctx context.Context, destDir string) error {
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	if _, err := os.Stat(filepath.Join(destDir, binName)); err == nil {
		return nil // 已就绪，跳过下载（幂等，避免重复网络请求）
	}
	_, err := cfst.Fetch(ctx, cfst.CFSTFetchOptions{DestDir: destDir})
	return err
}

// HealthPing 轻量网络体检：对若干关键域名做短超时 TCP 探测，失败仅返回告警（不阻塞安装）。
func HealthPing(ctx context.Context) []string {
	var warns []string
	targets := []string{
		"api.cloudflare.com:443",
		"dnspod.tencentcloudapi.com:443",
		"github.com:443",
	}
	d := net.Dialer{Timeout: 2 * time.Second}
	for _, t := range targets {
		c, err := d.DialContext(ctx, "tcp", t)
		if err != nil {
			warns = append(warns, fmt.Sprintf("网络体检失败（%s）: %v", t, err))
			continue
		}
		_ = c.Close()
	}
	return warns
}

// IsInstalled 检查目标目录是否已安装 cfopt（幂等判定）。
// 检查目标目录下 cfopt[.exe] 是否存在，以及 CfgDir 下 global.json 是否存在。
// 若两者都存在，视为「已安装」，后续仅做幂等检查，跳过首次预检。
func IsInstalled(opts InstallOptions) bool {
	exeName := "cfopt"
	if runtime.GOOS == "windows" {
		exeName = "cfopt.exe"
	}
	if _, err := os.Stat(filepath.Join(opts.Dir, exeName)); err != nil {
		return false
	}
	if _, err := os.Stat(filepath.Join(opts.CfgDir, "global.json")); err != nil {
		return false
	}
	return true
}

// CheckDirClean 检查 dir 目录是否「干净」（仅含 cfopt 自身的安装产物）。
// 返回：clean（true=仅含 cfopt 文件）/ foreignFiles（非 cfopt 文件列表）/ error。
// 计算方式：列出 dir 下的所有文件和目录（仅一层，不递归），
// 如果只有 cfopt[.exe]、conf/、assets/、global.json 或空目录，则视为干净。
func CheckDirClean(dir, exeName string) (clean bool, foreignFiles []string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return true, nil, nil // 目录不存在视为干净
		}
		return false, nil, common.Wrap("install:readdir", err)
	}

	known := map[string]bool{
		exeName:     true,
		"conf":      true,
		"assets":    true,
		"global.json": true,
	}

	for _, e := range entries {
		if known[e.Name()] {
			continue
		}
		foreignFiles = append(foreignFiles, e.Name())
	}

	return len(foreignFiles) == 0, foreignFiles, nil
}

// preInstallCheck 首次安装预检：检查目录可写性、cfst 可下载性、网络连通性，
// 并将结果追加到 res 的 Warnings 中（同时打印到终端让用户看到）。
func preInstallCheck(ctx context.Context, opts InstallOptions, res *InstallResult) {
	fmt.Println()
	fmt.Println("--- 首次安装预检 ---")

	// 1) 检查目标目录是否可写。
	// 尝试 MkdirAll + 创建临时文件，确保目录存在且可写。
	if err := os.MkdirAll(opts.Dir, 0o755); err != nil {
		w := fmt.Sprintf("目标目录不可写（%s）: %v", opts.Dir, err)
		res.Warnings = append(res.Warnings, w)
		fmt.Printf("⚠ %s\n", w)
		fmt.Println("  请换一个可写目录，或以管理员身份运行。")
	} else {
		tmpFile := filepath.Join(opts.Dir, ".cfopt-write-test")
		if err := os.WriteFile(tmpFile, []byte("test"), 0o600); err != nil {
			w := fmt.Sprintf("目标目录不可写（%s）: %v", opts.Dir, err)
			res.Warnings = append(res.Warnings, w)
			fmt.Printf("⚠ %s\n", w)
			fmt.Println("  请换一个可写目录，或以管理员身份运行。")
		} else {
			_ = os.Remove(tmpFile)
			fmt.Printf("✓ 目标目录可写: %s\n", opts.Dir)
		}
	}

	// 2) 检查 cfst 资产目录是否可创建。
	cfstDir := filepath.Join(opts.Dir, "assets", "cfst")
	if err := os.MkdirAll(cfstDir, 0o755); err != nil {
		w := fmt.Sprintf("cfst 资产目录不可创建（%s）: %v", cfstDir, err)
		res.Warnings = append(res.Warnings, w)
		fmt.Printf("⚠ %s\n", w)
		fmt.Println("  请检查目录权限，或稍后手动运行 `cfopt cfst fetch`。")
	} else {
		fmt.Printf("✓ cfst 目录可创建: %s\n", cfstDir)
	}

	// 3) 网络连通性（复用 HealthPing，但打印结果给用户看，而非仅记 warning）。
	fmt.Println("--- 网络连通性检测 ---")
	pingResults := HealthPing(ctx)
	if len(pingResults) == 0 {
		fmt.Println("✓ 网络连通性正常（所有目标可达）。")
	} else {
		for _, w := range pingResults {
			fmt.Printf("⚠ %s\n", w)
			res.Warnings = append(res.Warnings, w)
		}
		fmt.Println("  部分目标不可达，安装可能失败。请检查网络环境后重试。")
	}
	fmt.Println("--- 预检完成 ---")
	fmt.Println()
}

// RunInstall 一键安装（幂等）。按 opts.Mode 分支：
//   - portable：仅当 dir≠当前二进制目录才 SelfPlace；跳过 GlobalCommandInstaller；
//     cfst 落 filepath.Join(dir,"assets","cfst")；ProvisionConf(cfgDir)；HealthPing。
//   - system：SelfPlace→dir；调用 GlobalCommandInstaller（PATH/软链）；
//     ProvisionConf(cfgDir)；cfst 落 dir/assets/cfst；HealthPing；WithSchedule 仅记意图。
//
// 首次安装时（IsInstalled==false）自动执行 preInstallCheck。
func RunInstall(ctx context.Context, opts InstallOptions) (*InstallResult, error) {
	res := &InstallResult{Mode: opts.Mode}
	if opts.Dir == "" {
		return nil, fmt.Errorf("install: Dir 不能为空")
	}
	if err := validateInstallDir(opts.Dir); err != nil {
		return nil, err
	}

	// 首次安装预检：仅在「未安装」状态下执行，已安装跳过。
	if !IsInstalled(opts) {
		preInstallCheck(ctx, opts, res)
	} else {
		fmt.Println("检测到已安装状态，跳过首次预检，执行幂等安装。")
	}

	exe, exeErr := os.Executable()
	exeDir := ""
	if exeErr == nil {
		exeDir = filepath.Dir(exe)
	}

	// 1) 自安置二进制。
	// 便携模式：仅当目标目录与当前二进制目录不同才复制（同目录则跳过，二进制已在目录内）。
	if opts.Mode == ModePortable && opts.Dir == exeDir {
		res.SelfPlaced = true // 二进制已在目标目录内，视为已安置（幂等）
	} else {
		if exeErr != nil {
			res.Errors = append(res.Errors, "获取当前二进制路径失败: "+exeErr.Error())
		} else if _, e := SelfPlace(exe, opts.Dir); e != nil {
			res.Errors = append(res.Errors, "自安置失败: "+e.Error())
		} else {
			res.SelfPlaced = true
		}
	}

	// 2) 全局命令（PATH/软链）。
	// 便携模式：跳过（不写 PATH、不写注册表、不写 LOCALAPPDATA）。
	if opts.Mode == ModeSystem {
		if e := GlobalCommandInstaller(opts.Dir, runtime.GOOS); e != nil {
			res.Warnings = append(res.Warnings, "全局命令安装未完成（可稍后手动添加）: "+e.Error())
		} else {
			res.GlobalCommandInstalled = true
		}
	} else {
		res.GlobalCommandInstalled = false // 便携模式恒 false
	}

	// 3) conf 骨架。
	if e := ProvisionConf(opts.CfgDir); e != nil {
		res.Errors = append(res.Errors, "生成 conf 骨架失败: "+e.Error())
	} else {
		res.ConfInit = true
	}

	// 4) cfst 二进制就绪（落 Dir/assets/cfst，删目录即随配置一起清除）。
	if e := ensureCFST(ctx, filepath.Join(opts.Dir, "assets", "cfst")); e != nil {
		res.Warnings = append(res.Warnings, "cfst 下载失败（可稍后 `cfopt cfst fetch` 手动安装）: "+e.Error())
	} else {
		res.CFSTInstalled = true
	}

	// 5) 轻量网络体检（仅告警，不阻塞）。
	// 若是首次安装，预检中已打印 HealthPing 结果，此处不再重复追加到 warnings 避免重复。
	if IsInstalled(opts) {
		res.Warnings = append(res.Warnings, HealthPing(ctx)...)
	}

	// 调度注册意图：实际注册由 cmd 层在 RunInstall 返回后调用 runSchedule 完成（便携模式根本不触碰）。
	if opts.WithSchedule {
		res.ScheduleInstalled = true
	}
	return res, nil
}

// RunUninstall 一键卸载（best-effort，不交互）。
//   - portable：validateInstallDir(dir) → os.RemoveAll(dir) best-effort，列出删除失败项（如运行中的 exe）。
//   - system：validateInstallDir(dir) → GlobalCommandRemover(dir)（清 PATH/软链）→
//     若 RemoveData 则 RemoveDataDir(dir, cfgDir)；调度卸载由 cmd 层在调用前用 runSchedule("uninstall") 完成。
func RunUninstall(ctx context.Context, opts UninstallOptions) (*UninstallResult, error) {
	res := &UninstallResult{Mode: opts.Mode}
	if opts.Dir == "" {
		return nil, fmt.Errorf("install: Dir 不能为空")
	}
	if err := validateInstallDir(opts.Dir); err != nil {
		return nil, err
	}

	if opts.Mode == ModePortable {
		// 便携：best-effort 删除整个目录（删目录即干净退出）。
		if err := os.RemoveAll(opts.Dir); err != nil {
			// 列出删除失败的项（典型为 Windows 下运行中的 cfopt.exe 被锁定）。
			var failed []string
			_ = filepath.Walk(opts.Dir, func(p string, info os.FileInfo, walkErr error) error {
				if walkErr != nil {
					return nil
				}
				failed = append(failed, p)
				return nil
			})
			res.Failed = append(res.Failed, failed...)
			res.Warnings = append(res.Warnings, "部分文件删除失败（可能为运行中进程锁定），请退出本程序后手动删除该目录")
			res.Removed = append(res.Removed, "尝试删除便携目录: "+opts.Dir)
		} else {
			res.Removed = append(res.Removed, "便携目录: "+opts.Dir)
		}
		return res, nil
	}

	// 系统级：清理全局命令（PATH/软链）。
	if e := GlobalCommandRemover(opts.Dir, runtime.GOOS); e != nil {
		res.Failed = append(res.Failed, "全局命令移除失败: "+e.Error())
	} else {
		res.Removed = append(res.Removed, "全局命令（PATH/软链）")
	}
	// 可选全清（配置与数据目录）。
	if opts.RemoveData {
		if e := RemoveDataDir(opts.Dir, opts.CfgDir); e != nil {
			res.Failed = append(res.Failed, "数据目录清理失败: "+e.Error())
		} else {
			res.Removed = append(res.Removed, "安装目录与配置目录")
		}
	}
	return res, nil
}

// RemoveGlobalCommand 移除全局命令（跨平台分支）：Windows 从用户 PATH 删除 dir；其他删除 /usr/local/bin/cfopt 软链。
func RemoveGlobalCommand(dir string, goos string) error {
	if goos == "windows" {
		return removeGlobalCommandWindows(dir)
	}
	name := "cfopt"
	if goos == "windows" {
		name = "cfopt.exe"
	}
	link := filepath.Join("/usr/local/bin", name)
	if _, err := os.Lstat(link); err == nil {
		if err := os.Remove(link); err != nil {
			return common.Wrap("install:remove-symlink", err)
		}
	}
	return nil
}

// removeGlobalCommandWindows 从用户级 PATH 删除 dir（幂等：不含则跳过）。
func removeGlobalCommandWindows(dir string) error {
	script := `$d=$env:CFOPT_INSTALL_DIR;` +
		`$p=[Environment]::GetEnvironmentVariable('Path','User');` +
		`$parts=($p -split ';') | Where-Object { $_ -and $_ -ne $d };` +
		`[Environment]::SetEnvironmentVariable('Path',($parts -join ';'),'User')`
	cmd := exec.Command("powershell", "-ExecutionPolicy", "Bypass", "-Command", script)
	cmd.Env = append(os.Environ(), "CFOPT_INSTALL_DIR="+dir)
	if out, err := cmd.CombinedOutput(); err != nil {
		return common.Wrap("install:win-path-remove:"+strings.TrimSpace(string(out)), err)
	}
	return nil
}

// RemoveDataDir 全清：删除安装目录与配置目录（路径守卫，拒绝危险目录与 ".."）。
// 仅应在用户显式确认「全清」后调用。
func RemoveDataDir(installDir, cfgDir string) error {
	for _, d := range []string{installDir, cfgDir} {
		if d == "" {
			continue
		}
		if err := validateInstallDir(d); err != nil {
			return err
		}
		if _, err := os.Stat(d); err != nil {
			continue // 不存在则跳过
		}
		if err := os.RemoveAll(d); err != nil {
			return common.Wrap("install:remove-data:"+d, err)
		}
	}
	return nil
}

// copyFile 将 src 复制到 dst。
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return common.Wrap("install:copy:open", err)
	}
	defer func() { _ = in.Close() }()
	out, err := os.Create(dst)
	if err != nil {
		return common.Wrap("install:copy:create", err)
	}
	defer func() { _ = out.Close() }()
	if _, err := io.Copy(out, in); err != nil {
		return common.Wrap("install:copy:io", err)
	}
	return nil
}
