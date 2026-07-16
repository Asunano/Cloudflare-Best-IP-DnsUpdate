package ipc

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// 本文件用契约测试「锁死」protocol.go 的现状字段标签（snake_case），
// 防止未来被误改回 PascalCase。字段标签本身已在生产代码中固定，此处仅做回归断言。

// TestVersionInfo_SnakeCase 断言 VersionInfo 序列化键为 version/commit/built_at。
func TestVersionInfo_SnakeCase(t *testing.T) {
	b, err := json.Marshal(VersionInfo{Version: "1.0", Commit: "abc", BuiltAt: "2024"})
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &m))
	for _, k := range []string{"version", "commit", "built_at"} {
		_, ok := m[k]
		assert.Truef(t, ok, "VersionInfo 缺少 snake_case 键 %q", k)
	}
	for _, k := range []string{"Version", "Commit", "BuiltAt"} {
		_, ok := m[k]
		assert.Falsef(t, ok, "VersionInfo 不应出现 PascalCase 键 %q", k)
	}
}

// TestDaemonStatus_SnakeCase 断言 DaemonStatus 序列化键为 state。
func TestDaemonStatus_SnakeCase(t *testing.T) {
	b, err := json.Marshal(DaemonStatus{State: "running"})
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &m))
	_, ok := m["state"]
	assert.True(t, ok, "DaemonStatus 缺少键 state")
	_, ok = m["State"]
	assert.False(t, ok, "DaemonStatus 不应出现 PascalCase 键 State")
}

// TestProgressEvent_SnakeCase 断言 ProgressEvent 序列化键为 req_id/phase/cur/total/message。
func TestProgressEvent_SnakeCase(t *testing.T) {
	b, err := json.Marshal(ProgressEvent{ReqID: 7, Phase: "write", Cur: 3, Total: 5, Message: "x"})
	require.NoError(t, err)
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &m))
	for _, k := range []string{"req_id", "phase", "cur", "total", "message"} {
		_, ok := m[k]
		assert.Truef(t, ok, "ProgressEvent 缺少 snake_case 键 %q", k)
	}
	for _, k := range []string{"ReqID", "Phase", "Cur", "Total", "Message"} {
		_, ok := m[k]
		assert.Falsef(t, ok, "ProgressEvent 不应出现 PascalCase 键 %q", k)
	}
}
