package geo

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

// 用本地 httptest 模拟 geo 公共服务，覆盖 APIURL。
func withGeoServer(t *testing.T, body string, status int, fn func()) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	orig := APIURL
	APIURL = srv.URL
	defer func() { APIURL = orig }()

	fn()
}

// TestGetCountryCode_CN 验证 country_code=CN 时归一为小写 "cn"。
func TestGetCountryCode_CN(t *testing.T) {
	withGeoServer(t, `{"ip":"1.2.3.4","country_code":"CN"}`, http.StatusOK, func() {
		code, err := GetCountryCode(context.Background())
		assert.NoError(t, err)
		assert.Equal(t, "cn", code)
	})
}

// TestGetCountryCode_US 验证非 CN 返回对应小写国家码。
func TestGetCountryCode_US(t *testing.T) {
	withGeoServer(t, `{"ip":"1.2.3.4","country_code":"US"}`, http.StatusOK, func() {
		code, err := GetCountryCode(context.Background())
		assert.NoError(t, err)
		assert.Equal(t, "us", code)
	})
}

// TestGetCountryCode_CountryFallback 兼容仅返回 country=China 而无 country_code 的响应。
func TestGetCountryCode_CountryFallback(t *testing.T) {
	withGeoServer(t, `{"ip":"1.2.3.4","country":"China"}`, http.StatusOK, func() {
		code, err := GetCountryCode(context.Background())
		assert.NoError(t, err)
		assert.Equal(t, "cn", code, "country=China 应推断为 cn")
	})
}

// TestIsCountry 验证 IsCountry 大小写不敏感地匹配任意国家码。
func TestIsCountry(t *testing.T) {
	withGeoServer(t, `{"country_code":"JP"}`, http.StatusOK, func() {
		ok, err := IsCountry(context.Background(), "jp")
		assert.NoError(t, err)
		assert.True(t, ok)

		ok, err = IsCountry(context.Background(), "CN")
		assert.NoError(t, err)
		assert.False(t, ok, "JP 不应匹配 CN")
	})
}

// TestIsInChina 验证便捷方法等价于 IsCountry(CN)。
func TestIsInChina(t *testing.T) {
	withGeoServer(t, `{"country_code":"CN"}`, http.StatusOK, func() {
		ok, err := IsInChina(context.Background())
		assert.NoError(t, err)
		assert.True(t, ok)
	})
	withGeoServer(t, `{"country_code":"DE"}`, http.StatusOK, func() {
		ok, err := IsInChina(context.Background())
		assert.NoError(t, err)
		assert.False(t, ok)
	})
}

// TestGetGeo_ErrorFallback 网络异常/非 200/非法 JSON 均返回零值且不报错。
func TestGetGeo_ErrorFallback(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"non200", http.StatusInternalServerError, "boom"},
		{"badjson", http.StatusOK, "not-json"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withGeoServer(t, c.body, c.status, func() {
				info, err := GetGeo(context.Background())
				assert.NoError(t, err)
				assert.Empty(t, info.CountryCode, "异常时应返回空国家码")
			})
		})
	}
}

// TestWithMirrorFallback 验证：首次直连失败时，WithMirrorFallback 自动用 ChinaMirrorProxy 改写 URL 重试。
// 通过模拟 do 函数追踪调用来验证逻辑，不涉及真实网络。
func TestWithMirrorFallback(t *testing.T) {
	var calls []string
	do := func(ctx context.Context, url string) error {
		calls = append(calls, url)
		if len(calls) == 1 {
			return fmt.Errorf("first attempt failed")
		}
		return nil
	}

	err := WithMirrorFallback(context.Background(), "https://github.com/owner/repo/releases/download/v1/asset.zip", 30*time.Second, do)
	assert.NoError(t, err, "首次失败后应回退成功")
	assert.Len(t, calls, 2, "应调用两次（直连+镜像回退）")
	assert.Equal(t, "https://github.com/owner/repo/releases/download/v1/asset.zip", calls[0])
	assert.Equal(t, "https://v4.gh-proxy.org/https://github.com/owner/repo/releases/download/v1/asset.zip", calls[1],
		"回退 URL 应为 ChinaMirrorProxy + 原始 URL")
}

// TestWithMirrorFallback_NonHTTPS 验证非 https 原始 URL 不触发回退（仅适用于 GitHub 直连加速）。
func TestWithMirrorFallback_NonHTTPS(t *testing.T) {
	var calls int
	do := func(ctx context.Context, url string) error {
		calls++
		return fmt.Errorf("fail")
	}
	err := WithMirrorFallback(context.Background(), "http://example.com/file.zip", 30*time.Second, do)
	assert.Error(t, err, "非 https 不应回退")
	assert.Equal(t, 1, calls, "非 https 仅尝试一次，不触发镜像回退")
}

// TestWithMirrorFallback_DirectSuccess 验证直连成功时不触发回退。
func TestWithMirrorFallback_DirectSuccess(t *testing.T) {
	var calls int
	do := func(ctx context.Context, url string) error {
		calls++
		return nil
	}
	err := WithMirrorFallback(context.Background(), "https://github.com/owner/repo/releases/download/v1/asset.zip", 30*time.Second, do)
	assert.NoError(t, err)
	assert.Equal(t, 1, calls, "直连成功不应触发回退")
}
