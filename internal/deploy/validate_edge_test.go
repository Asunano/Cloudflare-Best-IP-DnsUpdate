package deploy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestValidateCloudflare_shortTokenRejected CF Token 长度红线：<30 应在发请求前被拒（不触网）。
func TestValidateCloudflare_shortTokenRejected(t *testing.T) {
	if _, err := ValidateCloudflare(context.Background(), "short"); err == nil {
		t.Fatal("长度不足 30 的 CF Token 应被拒绝")
	}
}

// TestValidateCloudflare_emptyTokenRejected 空 Token 应被拒绝。
func TestValidateCloudflare_emptyTokenRejected(t *testing.T) {
	if _, err := ValidateCloudflare(context.Background(), ""); err == nil {
		t.Fatal("空 CF Token 应被拒绝")
	}
}

// TestValidateDNSPod_badCredentials 非法凭证（AuthFailure）应返回错误。
func TestValidateDNSPod_badCredentials(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{
				"Error": map[string]any{"Code": "AuthFailure", "Message": "secret id or key error"},
			},
		})
	}))
	defer srv.Close()

	if _, err := validateDNSPodWithBaseURL(context.Background(), "bad", "bad", srv.URL); err == nil {
		t.Fatal("非法 DNSPod 凭证应返回错误")
	}
}

// TestValidateDNSPod_emptySecret 空 SecretID/SecretKey 应直接报错（不触网）。
func TestValidateDNSPod_emptySecret(t *testing.T) {
	if _, err := ValidateDNSPod(context.Background(), "", ""); err == nil {
		t.Fatal("空 SecretID/SecretKey 应返回错误")
	}
}

// TestValidateDNSPod_emptyDomainList 空域名列表不应报错，由上层判断可访问性。
func TestValidateDNSPod_emptyDomainList(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"Response": map[string]any{"DomainList": []any{}, "TotalCount": 0},
		})
	}))
	defer srv.Close()

	domains, err := validateDNSPodWithBaseURL(context.Background(), "id", "key", srv.URL)
	if err != nil {
		t.Fatalf("空域名列表不应报错，got=%v", err)
	}
	if len(domains) != 0 {
		t.Fatalf("空域名列表应返回空切片，got=%v", domains)
	}
}
