package dns

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// 以下测试验证「逐线路即时同步」的 dnspodModule 胶水逻辑：
// SyncLine（单线同步）/ SyncUnified（统一子域收尾）/ Sync 跳过 isp_lines 配置。
// 真实 diff 逻辑由 multiline_test.go 的 SyncMultiLine 用例覆盖。

// ispLinesConfig 构造一个 isp_lines 单值 DNSPod 配置，lines 为各线路名。
// 每条线路的 IP 文件写到 dir/line.iplist（内容由 ips 提供），并返回配置。
func ispLinesConfig(t *testing.T, dir string, lines []string, unified string) *config.Config {
	t.Helper()
	isp := map[string]config.ISPConf{}
	for _, ln := range lines {
		f := filepath.Join(dir, ln+".iplist")
		// .iplist 格式：IP|延迟|速度|地区码
		require.NoError(t, os.WriteFile(f, []byte("1.1.1.1|10|100|HKG\n8.8.8.8|12|90|TPE\n9.9.9.9|11|95|HKG\n"), 0o644))
		conf := config.ISPConf{}
		conf.IPSource.Files = map[string]string{ln: f}
		isp[ln] = conf
	}
	return &config.Config{
		DNSPod: &config.DNSPodConfig{
			Enabled:         true,
			Mode:            "isp_lines",
			SpeedTestPerISP: true,
			Domain:          "example.com",
			SubDomain:       "www",
			SubDomains:      map[string]string{"电信": "www", "联通": "www", "移动": "www", "默认": "www"},
			DefaultLine:     "电信",
			TTL:             600,
			DeleteMode:      "none",
			SubDomainUnified: unified,
			ISP:             isp,
		},
	}
}

// fakeDNSPodServer 模拟 DNSPod API：DescribeRecordList 返回无数据（走创建分支），其余返回成功。
func fakeDNSPodServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
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
	return srv
}

// TestDNSPodModule_SyncSkipsISPLines 验证整模块 Sync 跳过 isp_lines 配置（改由逐线路路径处理），
// 不触发任何 API 调用（无 IP 文件读取、无 provider 构造副作用），返回空结果。
func TestDNSPodModule_SyncSkipsISPLines(t *testing.T) {
	dir := t.TempDir()
	cfg := ispLinesConfig(t, dir, []string{"电信", "联通", "移动", "默认"}, "")

	res, err := dnspodModule{}.Sync(context.Background(), cfg)
	require.NoError(t, err)
	assert.Equal(t, 0, res.Updated+res.Created+res.Deleted, "isp_lines 配置应被跳过，无同步活动")
	assert.Empty(t, res.Errors, "不应产生错误")
}

// TestDNSPodModule_SyncLineSkipsNonPerLine 验证 job 指向非 isp_lines 配置时 SyncLine 直接返回空（不触碰 API）。
func TestDNSPodModule_SyncLineSkipsNonPerLine(t *testing.T) {
	cfg := &config.Config{
		DNSPod: &config.DNSPodConfig{
			Enabled:   true,
			Mode:      "single",
			Domain:    "example.com",
			SubDomain: "www",
			IPFilePath: filepath.Join(t.TempDir(), "ips.txt"),
			TTL:       600,
		},
	}
	job := LineSpeedtestJob{Domain: "example.com", Line: "默认", SubDomain: "www"}
	res, err := dnspodModule{}.SyncLine(context.Background(), cfg, job)
	require.NoError(t, err)
	assert.Zero(t, res.Updated+res.Created+res.Deleted, "非 isp_lines 应直接返回空结果")
	assert.Empty(t, res.Errors)
}

// TestDNSPodModule_SyncUnifiedNoUnified 验证未配置统一子域时 SyncUnified 直接返回空（不走 API）。
func TestDNSPodModule_SyncUnifiedNoUnified(t *testing.T) {
	dir := t.TempDir()
	cfg := ispLinesConfig(t, dir, []string{"电信", "联通"}, "")

	res, err := dnspodModule{}.SyncUnified(context.Background(), cfg)
	require.NoError(t, err)
	assert.Zero(t, res.Updated+res.Created+res.Deleted, "无统一子域应返回空结果")
	assert.Empty(t, res.Errors)
}

// TestDNSPodModule_SyncLineCreatesViaNoData 验证 SyncLine 对单条线路走「NoData→创建」分支。
func TestDNSPodModule_SyncLineCreatesViaNoData(t *testing.T) {
	dir := t.TempDir()
	cfg := ispLinesConfig(t, dir, []string{"电信", "联通", "移动", "默认"}, "")

	srv := fakeDNSPodServer(t)
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	job := LineSpeedtestJob{Domain: "example.com", Line: "电信", SubDomain: "www"}
	res, err := dnspodModule{}.SyncLine(context.Background(), cfg, job)
	require.NoError(t, err)
	assert.Equal(t, 3, res.Created, "单线路应为 3 个 IP 各创建一条记录")
	assert.Zero(t, res.Deleted)
	assert.Empty(t, res.Errors)
}

// TestDNSPodModule_SyncUnifiedCreatesViaNoData 验证 SyncUnified 为统一子域创建一条记录。
func TestDNSPodModule_SyncUnifiedCreatesViaNoData(t *testing.T) {
	dir := t.TempDir()
	cfg := ispLinesConfig(t, dir, []string{"电信", "联通"}, "all")

	srv := fakeDNSPodServer(t)
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	res, err := dnspodModule{}.SyncUnified(context.Background(), cfg)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Created, "统一子域应创建 1 条记录")
	assert.Empty(t, res.Errors)
}

// TestDNSPodModule_SyncLineUsesBareDomain 回归守护（DomainNotExists bug）：
// 多域名配置的 map key 是完整主机名（如 mmmmm.drxian.cn），仅用于定位配置与 DomainFilter 过滤；
// 传给 DNSPod API 的 Domain 字段必须是注册主域名（d.Domain，如 drxian.cn），子域由 resolver 放入 SubDomain。
// 本测试捕获 SyncLine 实际发出的 DescribeRecordList 的 Domain 字段并断言其为裸主域名。
func TestDNSPodModule_SyncLineUsesBareDomain(t *testing.T) {
	dir := t.TempDir()
	// 线路 IP 文件（resolver 本地读取，与 API Domain 无关）。
	ipFile := filepath.Join(dir, "电信.iplist")
	require.NoError(t, os.WriteFile(ipFile, []byte("1.1.1.1|10|100|HKG\n"), 0o644))

	key := "mmmmm.drxian.cn" // 多域名 map key（完整主机名）
	bare := "drxian.cn"      // 配置里的注册主域名 d.Domain
	isp := map[string]config.ISPConf{}
	conf := config.ISPConf{}
	conf.IPSource.Files = map[string]string{"电信": ipFile}
	isp["电信"] = conf

	cfg := &config.Config{
		DNSPodDomains: map[string]*config.DNSPodConfig{
			key: {
				Enabled:         true,
				Mode:            "isp_lines",
				SpeedTestPerISP: true,
				Domain:          bare,
				SubDomain:       "mmmmm",
				TTL:             600,
				ISP:             isp,
			},
		},
	}

	var capturedDomain string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		if r.Header.Get("X-TC-Action") == "DescribeRecordList" {
			if d, ok := payload["Domain"].(string); ok {
				capturedDomain = d
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{"Error": map[string]any{"Code": "ResourceNotFound.NoDataOfRecord", "Message": "no data"}},
		})
	}))
	defer srv.Close()
	orig := dnspodBaseURL
	dnspodBaseURL = srv.URL
	defer func() { dnspodBaseURL = orig }()

	job := LineSpeedtestJob{Domain: key, Line: "电信", SubDomain: "mmmmm"}
	_, err := dnspodModule{}.SyncLine(context.Background(), cfg, job)
	require.NoError(t, err)
	assert.Equal(t, bare, capturedDomain, "SyncLine 必须向 DNSPod 传注册主域名 d.Domain，而非多域名 map key（完整主机名）")
}
