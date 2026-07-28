package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestBuildPanelCronScript 验证面板调度命令生成：绝对路径 + cd 工作目录 + schedule run --once + 日志重定向。
func TestBuildPanelCronScript(t *testing.T) {
	script, err := buildPanelCronScript("/opt/cfopt/cfopt")
	require.NoError(t, err)
	assert.Contains(t, script, "cd /opt/cfopt", "应先 cd 到工作目录以加载默认 conf")
	assert.Contains(t, script, "/opt/cfopt/cfopt schedule run --once", "应使用绝对二进制路径")
	assert.Contains(t, script, ">> /opt/cfopt/cfopt-cron.log 2>&1", "应重定向日志")
}

// TestBuildPanelCronScript_WindowsPath 验证 Windows 风格路径（正斜杠写法）也能正确拼装。
// 注：filepath.Dir 按运行平台分隔符解析，这里用正斜杠以保证在 Linux 测试机上可解析。
func TestBuildPanelCronScript_WindowsPath(t *testing.T) {
	script, err := buildPanelCronScript(`C:/cfopt/cfopt.exe`)
	require.NoError(t, err)
	assert.Contains(t, script, `C:/cfopt/cfopt.exe schedule run --once`)
	assert.Contains(t, script, "cd C:/cfopt")
}
