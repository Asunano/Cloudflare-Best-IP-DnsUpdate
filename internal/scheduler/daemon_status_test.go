package scheduler

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestNewDaemonStatusOnly_Status_NoNilPanic 验证仅查询系统服务状态而构造的 Daemon
// （scheduler 与 cfg 均为 nil）调用 Status() 时不会因空指针而 panic。
//
// 背景：daemon.status IPC 方法只需查询系统服务（Windows Service / systemd / launchd）
// 的运行状态（running/stopped/unknown），无需构建 Syncer，因此 NewDaemonStatusOnly
// 故意以 nil scheduler/cfg 构造。Status() 仅使用 service.New(d, serviceConfig())
// 与 svc.Status()，不触及 scheduler/cfg，故应安全。
//
// 在测试环境中 kardianos/service 可能返回 error 或 "unknown"（服务未安装），
// 这里只断言“不 panic”即可。若 Status() 的实现被改坏、意外走到依赖
// scheduler/cfg 的路径，则会触发 panic/失败，正好覆盖回归。
func TestNewDaemonStatusOnly_Status_NoNilPanic(t *testing.T) {
	assert.NotPanics(t, func() {
		d := NewDaemonStatusOnly()
		state, err := d.Status()
		// Status() 的实现保证返回值非空的合法状态字符串（"running"/"stopped"/"unknown"，
		// 出错时回落到 "unknown"），此处断言非空以验证返回契约，而非无意义地取地址判 nil。
		assert.NotEmpty(t, state, "Status() 应返回非空状态字符串")
		_ = err
	})
}
