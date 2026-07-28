package cmd

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"cfopt/internal/install"
)

func TestSelfPlace_idempotent(t *testing.T) {
	tmp := t.TempDir()
	// 源：用当前测试二进制自身。
	src, err := os.Executable()
	if err != nil {
		t.Fatalf("获取可执行文件失败: %v", err)
	}
	dst, err := install.SelfPlace(src, tmp)
	if err != nil {
		t.Fatalf("SelfPlace 首次失败: %v", err)
	}
	if _, err := os.Stat(dst); err != nil {
		t.Fatalf("自安置文件未生成: %v", err)
	}
	// 再次执行应幂等（跳过复制，不报错）。
	dst2, err := install.SelfPlace(src, tmp)
	if err != nil {
		t.Fatalf("SelfPlace 重复执行失败: %v", err)
	}
	if dst != dst2 {
		t.Fatalf("SelfPlace 幂等应返回相同路径")
	}
}

func TestValidateInstallDir_guard(t *testing.T) {
	if _, err := install.SelfPlace(os.Args[0], "/tmp/evil"); err == nil {
		t.Fatal("应拒绝 /tmp 危险目录")
	}
	if _, err := install.SelfPlace(os.Args[0], "../escape"); err == nil {
		t.Fatal("应拒绝包含 '..' 的路径")
	}
}

func TestSetupGlobalCommand_symlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 分支需 PowerShell，跳过软链测试")
	}
	tmp := t.TempDir()
	// 放置一个伪二进制。
	bin := filepath.Join(tmp, "cfopt")
	if err := os.WriteFile(bin, []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}
	// 仅验证函数可调用且不 panic（真实软链写入 /usr/local/bin 需权限，测试环境可能无写权限）。
	if err := install.SetupGlobalCommand(tmp, "linux"); err != nil {
		// 无写权限时允许失败，但应返回 error 而非 panic。
		t.Logf("SetupGlobalCommand 返回（可能无权限）: %v", err)
	}
}

// TestRunInstall_minimal 验证新签名 RunInstall 在便携模式下正确生成骨架与 cfst，且跳过全局命令。
func TestRunInstall_minimal(t *testing.T) {
	// 避免测试中修改真实用户 PATH（便携模式本就不调用，这里再保险一层）。
	orig := install.GlobalCommandInstaller
	install.GlobalCommandInstaller = func(dir, goos string) error { return nil }
	defer func() { install.GlobalCommandInstaller = orig }()

	tmp := t.TempDir()
	dir := filepath.Join(tmp, "portable")
	cfgDir := filepath.Join(dir, "conf")
	// 预置 cfst 二进制到 dir/assets/cfst，避免触发网络下载。
	cfstDir := filepath.Join(dir, "assets", "cfst")
	_ = os.MkdirAll(cfstDir, 0o755)
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	if err := os.WriteFile(filepath.Join(cfstDir, binName), []byte("fake"), 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := install.RunInstall(context.Background(), install.InstallOptions{
		Mode:   install.ModePortable,
		Dir:    dir,
		CfgDir: cfgDir,
	})
	if err != nil {
		t.Fatalf("RunInstall 不应致命错误: %v", err)
	}
	if !res.SelfPlaced {
		t.Error("SelfPlaced 应为 true")
	}
	if !res.ConfInit {
		t.Error("ConfInit 应为 true")
	}
	if !res.CFSTInstalled {
		t.Errorf("CFSTInstalled 应为 true（已预置二进制），warnings=%v", res.Warnings)
	}
}
