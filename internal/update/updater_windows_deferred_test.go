//go:build windows

package update

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestReplaceWindowsDeferred_WritesBatchAndReturns 验证 Windows 自更新「延迟替换」路径：
// replaceWindowsDeferred 在 currentBin 所在目录生成 cfopt-update.bat（内容与父 PID 等待、
// move 替换、自删一致），并以 `cmd /c start ""` 分离启动（不阻塞、释放文件锁），
// 随后由父进程退出触发 bat 完成最终替换。本测试验证：
//  1. 返回 nil 错误（bat 成功生成并启动）；
//  2. bat 写入到 currentBin 所在目录（而非 cwd）；
//  3. bat 内容含父 PID 等待、move /Y 替换、del 自删逻辑。
func TestReplaceWindowsDeferred_WritesBatchAndReturns(t *testing.T) {
	dir := t.TempDir()
	// 模拟下载完成的临时文件 cfopt.download（replaceWindowsDeferred 会先检查其存在）。
	tmp := filepath.Join(dir, "cfopt.download")
	require.NoError(t, os.WriteFile(tmp, []byte("downloaded-binary"), 0o644))

	// currentBin 指向 dir 下的 cfopt.exe（仅用其目录）。
	currentBin := filepath.Join(dir, "cfopt.exe")

	err := replaceWindowsDeferred(currentBin, tmp, os.Getpid())
	require.NoError(t, err, "replaceWindowsDeferred 应成功生成并分离启动 bat")

	// bat 应写入 currentBin 所在目录。
	bat := filepath.Join(dir, "cfopt-update.bat")
	content, rerr := os.ReadFile(bat)
	require.NoError(t, rerr, "bat 应写入 currentBin 所在目录")
	body := string(content)

	assert.Contains(t, body, "@echo off", "应以 @echo off 开头")
	assert.Contains(t, body, `cd /d "`+dir+`"`, "应切换到 currentBin 所在绝对目录")
	assert.Contains(t, body, ":wait", "应包含等待循环标签")
	assert.Contains(t, body, `tasklist | find "`+strconv.Itoa(os.Getpid())+`" >nul && goto wait`,
		"应等待父 PID 退出（延迟替换核心）")
	assert.Contains(t, body, "move /Y cfopt.exe cfopt.old", "应将旧 exe 备份为 cfopt.old")
	assert.Contains(t, body, "move /Y cfopt.download cfopt.exe", "应将下载文件替换为 cfopt.exe")
	assert.Contains(t, body, `del "%~f0"`, "应自删批处理脚本（释放锁后清理）")
}
