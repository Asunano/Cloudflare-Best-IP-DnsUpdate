package scheduler

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestServiceConfig_ArgumentsAndWorkDir 锁定 systemd/服务单元的两个关键字段（历史 bug 回归锁）：
//
//  1. Arguments 必须为 `schedule run [--config-dir <abs>]`。曾因缺失 Arguments 导致
//     ExecStart 为裸二进制：非交互终端下打印菜单用法即退出，服务被 systemd 每 120s
//     反复重启却永远不执行同步。
//  2. WorkingDirectory 必须是配置目录的**父目录**（配置里 ./assets/data、conf/ 等
//     相对路径的基准）。曾因直接把 conf 目录写入 WorkingDirectory，导致服务 cwd
//     变成 .../conf，同步时报 `open ./assets/data/...: no such file or directory`。
func TestServiceConfig_ArgumentsAndWorkDir(t *testing.T) {
	cfgDir := filepath.Join(t.TempDir(), "conf")

	d := NewDaemonWithConfigDir(nil, nil, 0, false, cfgDir)
	sc := d.serviceConfig()

	require.Equal(t, []string{"schedule", "run", "--config-dir", cfgDir}, sc.Arguments,
		"ExecStart 必须携带 schedule run 与绝对 --config-dir")
	assert.Equal(t, filepath.Dir(cfgDir), sc.WorkingDirectory,
		"WorkingDirectory 必须是配置目录的父目录")
}

// TestServiceConfig_NoConfigDir 未指定配置目录时（如 status-only 场景）：
// Arguments 仍必须含 schedule run；WorkingDirectory 回退为二进制所在目录。
func TestServiceConfig_NoConfigDir(t *testing.T) {
	sc := NewDaemonStatusOnly().serviceConfig()

	assert.Equal(t, []string{"schedule", "run"}, sc.Arguments)
	assert.NotEmpty(t, sc.WorkingDirectory, "应回退为二进制所在目录")
}
