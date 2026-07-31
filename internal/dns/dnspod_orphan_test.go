package dns

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// ---------------------------------------------------------------------------
// #4：DNSPod 孤儿记录清理
// 仅清理「此前由 cfopt 管理（已持久化）且当前 Lines() 不再包含」的线路记录，
// 删除前通过托管状态文件精确圈定范围，避免误删用户手动添加的记录。
// ---------------------------------------------------------------------------

// seedOrphanRecord 通过真实 provider 调用在测试 API 上创建一条「孤儿线路」记录，
// 并返回其所在 key 信息。借助 dnspodLineServer 的内存状态模拟线上记录。
func newOrphanProvider(t *testing.T, srv *dnspodLineServer, dataDir string) *DNSPodProvider {
	t.Helper()
	cfg := &config.DNSPodConfig{
		SecretID:  "id",
		SecretKey: "key",
		Domain:    "example.com",
		Enabled:   true,
	}
	p := NewDNSPodProviderWithDataDir(cfg, dataDir)
	p.baseURL = srv.srv.URL
	return p
}

// TestDNSPodCleanupOrphanLines_removesOrphan 当前仅保留 联通，持久化状态含 电信(孤儿) → 应删除电信记录。
func TestDNSPodCleanupOrphanLines_removesOrphan(t *testing.T) {
	srv := newDNSPodLineServer(t)
	dataDir := t.TempDir()
	p := newOrphanProvider(t, srv, dataDir)

	// 预置一条「电信」线路记录（模拟此前同步产生、但当前配置已移除）。
	ctx := context.Background()
	require.NoError(t, p.UpsertLineRecord(ctx, "example.com", "telecom", "电信", "1.2.3.4", 600))

	// 持久化「此前管理的线路」状态：含 联通(仍在) + 电信(孤儿)。
	path := dnspodStatePath(dataDir, "example.com")
	require.NoError(t, saveDNSPodState(path, &dnspodManagedState{
		Domain: "example.com",
		Lines:  map[string]string{"联通": "unicom", "电信": "telecom"},
	}))

	// 当前 resolver 仅含 联通。
	resv := newMemLineProvider()
	resv.lines = []string{"联通"}
	resv.subOf = map[string]string{"联通": "unicom"}

	res := &SyncResult{}
	p.cleanupOrphanLines(ctx, resv, res)

	// 电信(孤儿) 记录应被删除 1 条；联通不受影响。
	assert.Equal(t, 1, res.Deleted, "孤儿线路电信记录应被删除 1 条")
	assert.Equal(t, 1, srv.Deletes(), "测试 API 应收到 1 次 DeleteRecord")
	assert.Empty(t, res.Errors, "清理不应报错")

	// 清理后持久化状态应仅保留当前线路 联通。
	st, err := loadDNSPodState(path)
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"联通": "unicom"}, st.Lines, "清理后状态应只剩当前线路")
}

// TestDNSPodCleanupOrphanLines_noOrphan 当前与持久化一致 → 不删除任何记录。
func TestDNSPodCleanupOrphanLines_noOrphan(t *testing.T) {
	srv := newDNSPodLineServer(t)
	dataDir := t.TempDir()
	p := newOrphanProvider(t, srv, dataDir)

	path := dnspodStatePath(dataDir, "example.com")
	require.NoError(t, saveDNSPodState(path, &dnspodManagedState{
		Domain: "example.com",
		Lines:  map[string]string{"联通": "unicom"},
	}))

	resv := newMemLineProvider()
	resv.lines = []string{"联通"}
	resv.subOf = map[string]string{"联通": "unicom"}

	res := &SyncResult{}
	p.cleanupOrphanLines(context.Background(), resv, res)

	assert.Equal(t, 0, res.Deleted, "无孤儿线路不应删除任何记录")
	assert.Equal(t, 0, srv.Deletes(), "测试 API 不应收到 DeleteRecord")
	assert.Empty(t, res.Errors)
}

// TestDNSPodCleanupOrphanLines_firstRun 首次运行无状态文件 → 仅写入当前状态，不删除。
func TestDNSPodCleanupOrphanLines_firstRun(t *testing.T) {
	srv := newDNSPodLineServer(t)
	dataDir := t.TempDir()
	p := newOrphanProvider(t, srv, dataDir)

	path := dnspodStatePath(dataDir, "example.com")
	// 确认状态文件起初不存在。
	_, err := os.Stat(path)
	require.True(t, os.IsNotExist(err), "首次运行前状态文件不应存在")

	resv := newMemLineProvider()
	resv.lines = []string{"联通"}
	resv.subOf = map[string]string{"联通": "unicom"}

	res := &SyncResult{}
	p.cleanupOrphanLines(context.Background(), resv, res)

	assert.Equal(t, 0, res.Deleted, "首次运行无持久化状态，不应删除")
	assert.Equal(t, 0, srv.Deletes(), "首次运行不应触发删除")
	// 应已落盘当前状态，供下次运行做差集。
	st, lerr := loadDNSPodState(path)
	require.NoError(t, lerr, "首次运行应写入托管状态")
	assert.Equal(t, map[string]string{"联通": "unicom"}, st.Lines)
}

// TestDNSPodCleanupOrphanLines_emptyDataDir dataDir 为空 → 直接返回，不读不写不删。
func TestDNSPodCleanupOrphanLines_emptyDataDir(t *testing.T) {
	srv := newDNSPodLineServer(t)
	// NewDNSPodProvider 构造 dataDir 为空。
	p := newOrphanProvider(t, srv, "")
	// 覆盖 baseURL（newOrphanProvider 在 dataDir 空时也已设置，这里确保一致）。
	p.domain = "example.com"

	resv := newMemLineProvider()
	resv.lines = []string{"联通"}
	resv.subOf = map[string]string{"联通": "unicom"}

	res := &SyncResult{}
	// 不应 panic，res 保持空。
	p.cleanupOrphanLines(context.Background(), resv, res)
	assert.Equal(t, 0, res.Deleted)
	assert.Equal(t, 0, srv.Deletes())
	assert.Empty(t, res.Errors)
}

// ---------------------------------------------------------------------------
// 托管状态文件辅助函数单测
// ---------------------------------------------------------------------------

// TestDNSPodStateFile_roundtrip 持久化/读取状态文件应保持一致；父目录自动创建。
func TestDNSPodStateFile_roundtrip(t *testing.T) {
	dataDir := t.TempDir()
	path := dnspodStatePath(dataDir, "foo.com")
	in := &dnspodManagedState{Domain: "foo.com", Lines: map[string]string{"默认": "www", "联通": "unicom"}}
	require.NoError(t, saveDNSPodState(path, in))
	out, err := loadDNSPodState(path)
	require.NoError(t, err)
	assert.Equal(t, in.Domain, out.Domain)
	assert.Equal(t, in.Lines, out.Lines)
}

// TestDNSPodStateFile_loadMissing 文件不存在应返回错误（供调用方判断首次运行）。
func TestDNSPodStateFile_loadMissing(t *testing.T) {
	_, err := loadDNSPodState(filepath.Join(t.TempDir(), "nope.managed.json"))
	assert.Error(t, err, "读取缺失状态文件应报错")
}

// TestSanitizeFilename 域名转为安全文件名（保留字母数字 . - _，其余替换）。
func TestSanitizeFilename(t *testing.T) {
	cases := map[string]string{
		"example.com":       "example.com",
		"a.b-c_d":           "a.b-c_d",
		"foo/bar.com":       "foo_bar.com",
		"weird:name*?.com":  "weird_name__.com",
	}
	for in, want := range cases {
		assert.Equal(t, want, sanitizeFilename(in), "sanitizeFilename(%q)", in)
	}
}

// TestDNSPodStatePath 路径应为 <dataDir>/dnspod/<sanitized>.managed.json。
func TestDNSPodStatePath(t *testing.T) {
	got := dnspodStatePath("/data", "example.com")
	want := filepath.Join("/data", "dnspod", "example.com.managed.json")
	assert.Equal(t, want, got)
}

// TestResolveDataDir 配置非空用配置值，否则回退 ./assets/data。
func TestResolveDataDir(t *testing.T) {
	withData := &config.Config{Global: &config.GlobalConfig{DataDir: "/custom/data"}}
	assert.Equal(t, "/custom/data", ResolveDataDir(withData))

	nilGlobal := &config.Config{}
	assert.Equal(t, "./assets/data", ResolveDataDir(nilGlobal))

	assert.Equal(t, "./assets/data", ResolveDataDir(nil))

	// 验证落盘 JSON 可被 json 包正常解析（结构稳定）。
	dataDir := t.TempDir()
	path := dnspodStatePath(dataDir, "x.com")
	_ = saveDNSPodState(path, &dnspodManagedState{Domain: "x.com", Lines: map[string]string{"默认": "www"}})
	raw, rerr := os.ReadFile(path)
	require.NoError(t, rerr)
	var probe map[string]any
	require.NoError(t, json.Unmarshal(raw, &probe))
	assert.Contains(t, probe, "domain")
	assert.Contains(t, probe, "lines")
}
