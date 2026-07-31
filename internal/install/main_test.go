package install

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// TestMain 将临时目录重定向到项目目录内（非 /tmp）。
// 安装目录守卫会拒绝 /tmp，而大量功能测试依赖 t.TempDir()（默认落在 /tmp 下）
// 作为便携安装目标；把 TMPDIR 指到非 /tmp 路径，既能满足「拒绝 /tmp」的安全契约，
// 又不误伤正常的便携安装测试。
func TestMain(m *testing.M) {
	if cwd, err := os.Getwd(); err == nil {
		dir := filepath.Join(cwd, ".gotmp-"+strconv.Itoa(os.Getpid()))
		_ = os.MkdirAll(dir, 0o755)
		_ = os.Setenv("TMPDIR", dir)
	}
	os.Exit(m.Run())
}
