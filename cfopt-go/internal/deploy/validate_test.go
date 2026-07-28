package deploy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"cfopt/internal/config"
)

func TestValidateCloudflare_ok(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/user/tokens/verify":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"success": true, "errors": []any{}, "result": map[string]any{"id": "tok-id"},
			})
		case r.URL.Path == "/zones":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"success": true, "errors": []any{},
				"result": []map[string]any{
					{"id": "zone-abc", "name": "example.com"},
					{"id": "zone-def", "name": "test.org"},
				},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	ctx := context.Background()
	// 通过内部 dns 构造器注入 baseURL（token 需 ≥30 字符以满足长度校验红线）。
	zones, err := validateCloudflareWithBaseURL(ctx, "valid-token-0123456789-abcdefghij", srv.URL)
	if err != nil {
		t.Fatalf("ValidateCloudflare 不应错误: %v", err)
	}
	if len(zones) != 2 || zones[0].Name != "example.com" || zones[0].ID != "zone-abc" {
		t.Fatalf("Zone 列表不符合预期: %+v", zones)
	}
}

func TestValidateCloudflare_badToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"errors":  []map[string]string{{"message": "invalid api token"}},
		})
	}))
	defer srv.Close()

	ctx := context.Background()
	if _, err := validateCloudflareWithBaseURL(ctx, "bad-token", srv.URL); err == nil {
		t.Fatal("无效 Token 应返回错误")
	}
}

func TestValidateDNSPod_ok(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{
				"DomainList": []map[string]any{
					{"DomainId": 1, "DomainName": "a.com", "Status": "ENABLE"},
					{"DomainId": 2, "DomainName": "b.com", "Status": "ENABLE"},
				},
				"TotalCount": 2,
			},
		})
	}))
	defer srv.Close()

	ctx := context.Background()
	domains, err := validateDNSPodWithBaseURL(ctx, "id", "key", srv.URL)
	if err != nil {
		t.Fatalf("ValidateDNSPod 不应错误: %v", err)
	}
	if len(domains) != 2 || domains[0] != "a.com" || domains[1] != "b.com" {
		t.Fatalf("域名列表不符合预期: %+v", domains)
	}
}

func TestParseLineSelection(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", []string{"默认"}},
		{"1", []string{"默认"}},
		{"1,3,4", []string{"默认", "移动", "电信"}},
		{"3,1,3", []string{"移动", "默认"}}, // 去重保序
		{"9,0", []string{"默认"}},         // 非法编号忽略
	}
	for _, c := range cases {
		got := ParseLineSelection(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("ParseLineSelection(%q)=%v 期望 %v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("ParseLineSelection(%q)=%v 期望 %v", c.in, got, c.want)
			}
		}
	}
}

func TestDeployPlan_BuildConf_cloudflare(t *testing.T) {
	p := &DeployPlan{
		Provider:   "cloudflare",
		Token:      "tok",
		ZoneID:     "z1",
		Domain:     "example.com",
		RecordName: "www",
	}
	v, err := p.BuildConf()
	if err != nil {
		t.Fatalf("BuildConf 不应错误: %v", err)
	}
	cfg, ok := v.(*config.CFDNSConfig)
	if !ok {
		t.Fatalf("CF BuildConf 应返回 *config.CFDNSConfig，got %T", v)
	}
	if !cfg.Enabled || cfg.API.Token != "tok" || cfg.API.ZoneID != "z1" || cfg.DNS.Domain != "example.com" {
		t.Fatalf("CF 配置字段不符合预期: %+v", cfg)
	}
}

func TestDeployPlan_BuildConf_dnspodMultiLine(t *testing.T) {
	p := &DeployPlan{
		Provider:  "dnspod",
		SecretID:  "id",
		SecretKey: "key",
		Domain:    "example.com",
		SubDomain: "www",
		Lines:     []string{"默认", "联通"},
	}
	v, err := p.BuildConf()
	if err != nil {
		t.Fatalf("BuildConf 不应错误: %v", err)
	}
	cfg, ok := v.(*config.DNSPodConfig)
	if !ok {
		t.Fatalf("DNSPod BuildConf 应返回 *config.DNSPodConfig，got %T", v)
	}
	if cfg.Mode != "isp_lines" {
		t.Fatalf("多线路应置 mode=isp_lines，got %q", cfg.Mode)
	}
	if len(cfg.ISP) != 2 {
		t.Fatalf("ISP 应含 2 条线路，got %d", len(cfg.ISP))
	}
	if _, ok := cfg.ISP["联通"]; !ok {
		t.Fatalf("ISP 应含 联通 线路")
	}
}
