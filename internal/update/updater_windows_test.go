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

// TestBuildUpdateBatchContent 验证 Windows 自更新批处理脚本内容正确：
// 绝对路径（cd /d dir）、等待父 PID 退出（:wait + tasklist|find）、自删（del "%~f0"）。
func TestBuildUpdateBatchContent(t *testing.T) {
	dir := `C:\prog\cfopt`
	pid := 1234
	content := buildUpdateBatchContent(dir, pid)

	assert.Contains(t, content, "@echo off", "应以 @echo off 开头")
	assert.Contains(t, content, `cd /d "C:\prog\cfopt"`, "应切换到二进制所在绝对目录")
	assert.Contains(t, content, ":wait", "应包含等待循环标签")
	assert.Contains(t, content, `tasklist | find "`+strconv.Itoa(pid)+`" >nul && goto wait`, "应等待父 PID 退出")
	assert.Contains(t, content, "move /Y cfopt.exe cfopt.old", "应将旧 exe 备份为 cfopt.old")
	assert.Contains(t, content, "move /Y cfopt.download cfopt.exe", "应将下载文件替换为 cfopt.exe")
	assert.Contains(t, content, `del "%~f0"`, "应自删批处理脚本")
}

// TestWriteUpdateBatchFile 验证脚本文件被正确写入磁盘，且内容包含父 PID 等待逻辑。
func TestWriteUpdateBatchFile(t *testing.T) {
	dir := t.TempDir()
	bat, err := writeUpdateBatchFile(dir, 999)
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(dir, "cfopt-update.bat"), bat, "脚本应命名为 cfopt-update.bat")

	content, err := os.ReadFile(bat)
	require.NoError(t, err)
	assert.Contains(t, string(content), `tasklist | find "999"`, "脚本应包含父 PID 等待")
	_ = os.Remove(bat)
}
