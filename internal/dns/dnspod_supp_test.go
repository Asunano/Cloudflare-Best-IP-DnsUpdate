package dns

// 二次检测补充测试（独立视角）：端到端验证 P0-1「DNSPod 首跑」。
//
// 现有测试已分别覆盖 listRecords 遇 NoData 返回空列表、UpsertLineRecord 创建分支；
// 但均未走通「首跑 → 集合差 → 创建记录」的完整 Sync 链路。本测试用 httptest 模拟
// DNSPod API：DescribeRecordList 返回 ResourceNotFound.NoDataOfRecord（记录不存在），
// CreateRecord 返回成功，随后驱动真实 DNSPodProvider.Sync，断言 Created == 目标 IP 数，
// 证明首跑确实走「创建记录」分支而非误抛错。

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// TestDNSPodProvider_SyncFirstRun_CreatesViaNoData 验证首跑 NoData → 创建记录分支。
func TestDNSPodProvider_SyncFirstRun_CreatesViaNoData(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		action := r.Header.Get("X-TC-Action")
		w.Header().Set("Content-Type", "application/json")
		if action == "DescribeRecordList" {
			// 首跑：记录不存在，返回无数据特型错误码。
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"Error": map[string]any{"Code": "ResourceNotFound.NoDataOfRecord", "Message": "no data"}},
			})
			return
		}
		// CreateRecord：成功返回 RecordId。
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{"RecordId": "rec-1", "RequestId": "x"},
		})
	}))
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	// 准备目标 IP 文件（单线路模式）。
	dir := t.TempDir()
	ipFile := filepath.Join(dir, "ips.txt")
	require.NoError(t, os.WriteFile(ipFile, []byte("1.1.1.1\n8.8.8.8\n9.9.9.9\n"), 0o644))

	cfg := &config.DNSPodConfig{
		Enabled:    true,
		Domain:     "example.com",
		SubDomain:  "www",
		Mode:       "single",
		IPFilePath: ipFile,
		TTL:        600,
		DeleteMode: "none",
	}
	p := NewDNSPodProvider(cfg)
	res, err := p.Sync(context.Background(), cfg)
	require.NoError(t, err, "首跑 NoData 不应报错")
	require.Equal(t, 3, res.Created, "应为 3 个目标 IP 各创建一条记录（走创建分支）")
	assert.Equal(t, 0, res.Deleted, "首跑无旧记录，删除数应为 0")
	assert.Empty(t, res.Errors, "首跑不应产生错误")
}

// TestDNSPodProvider_Sync_ExpiredIPWarns 验证 F3：IP 源文件过期时 Sync 返回过期告警（不阻断）。
func TestDNSPodProvider_Sync_ExpiredIPWarns(t *testing.T) {
	srv := dnspodNoDataServer(t)
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	dir := t.TempDir()
	ipFile := filepath.Join(dir, "ips.txt")
	require.NoError(t, os.WriteFile(ipFile, []byte("1.1.1.1\n8.8.8.8\n"), 0o644))
	// 把文件 mtime 设为 49h 前，触发过期告警。
	past := time.Now().Add(-49 * time.Hour)
	require.NoError(t, os.Chtimes(ipFile, past, past))

	cfg := &config.DNSPodConfig{
		Enabled: true, Domain: "example.com", SubDomain: "www",
		Mode: "single", IPFilePath: ipFile, TTL: 600, DeleteMode: "none",
	}
	p := NewDNSPodProvider(cfg)
	res, err := p.Sync(context.Background(), cfg)
	require.NoError(t, err)
	require.Equal(t, 2, res.Created)
	require.Len(t, res.Warnings, 1, "应返回 1 条过期告警")
	assert.Contains(t, res.Warnings[0], "已过期")
}

// TestDNSPodProvider_Sync_CountChangeWarns 验证 F4：IP 数量较上次 (.count) 变化 >50% 时严重警告。
func TestDNSPodProvider_Sync_CountChangeWarns(t *testing.T) {
	srv := dnspodNoDataServer(t)
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	dir := t.TempDir()
	ipFile := filepath.Join(dir, "ips.txt")
	require.NoError(t, os.WriteFile(ipFile, []byte("1.1.1.1\n8.8.8.8\n"), 0o644))
	// 上次记录 10 个 → 本次 2 个，变化 80% > 50%。
	require.NoError(t, os.WriteFile(ipFile+".count", []byte("10"), 0o644))

	cfg := &config.DNSPodConfig{
		Enabled: true, Domain: "example.com", SubDomain: "www",
		Mode: "single", IPFilePath: ipFile, TTL: 600, DeleteMode: "none",
	}
	p := NewDNSPodProvider(cfg)
	res, err := p.Sync(context.Background(), cfg)
	require.NoError(t, err)
	require.Equal(t, 2, res.Created)
	require.Len(t, res.Warnings, 1, "应返回 1 条数量剧变警告")
	assert.Contains(t, res.Warnings[0], "严重警告")
	assert.Contains(t, res.Warnings[0], "50%")
}

// dnspodNoDataServer 返回一个 DescribeRecordList 返回 NoData、CreateRecord 成功的 DNSPod API mock。
func dnspodNoDataServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		action := r.Header.Get("X-TC-Action")
		w.Header().Set("Content-Type", "application/json")
		if action == "DescribeRecordList" {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"Response": map[string]any{"Error": map[string]any{"Code": "ResourceNotFound.NoDataOfRecord", "Message": "no data"}},
			})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{"RecordId": "rec-1", "RequestId": "x"},
		})
	}))
}
