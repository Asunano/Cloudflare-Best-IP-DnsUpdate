// Package geo 提供客户端地理位置检测能力：通过公共服务（默认 https://api.ip.sb/geoip）
// 获取 ISO 3166-1 alpha-2 国家码，供任意模块自由判断地区，与镜像/网络策略解耦。
//
// 设计目标：独立且可自由调用。任意模块只需导入 geo 即可判断地区，例如：
//
//	// 模块 A：判断是否地区 B（如中国）
//	ok, _ := geo.IsCountry(ctx, "CN")
//	if ok { /* 走中国专属逻辑 */ }
//
//	// 模块 C：判断是否地区 F（如美国）
//	code, _ := geo.GetCountryCode(ctx)
//	if code == "us" { /* 走美国专属逻辑 */ }
//
// 任何网络/解析异常均按「未知」处理并返回零值，由调用方按「未知→非目标地区」对待，
// 绝不因检测失败阻断业务主流程。
package geo

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// APIURL 用于检测客户端地理位置的公共服务地址（测试可覆盖为 httptest）。
var APIURL = "https://api.ip.sb/geoip"

// ChinaMirrorProxy 中国地区推荐的 GitHub 镜像代理前缀：直接拼在原始 https 下载链接前，
// 形成 https://v4.gh-proxy.org/https://github.com/... 形式（gh-proxy 支持该写法）。
// 定义为 var 以便测试或高级用户覆盖为其他镜像。
var ChinaMirrorProxy = "https://v4.gh-proxy.org/"

// Info 地理位置信息。
type Info struct {
	CountryCode string `json:"country_code"` // ISO 3166-1 alpha-2，归一为小写，如 "cn"
	Country     string `json:"country"`      // 国家名，如 "China"
	IP          string `json:"ip"`
}

// GetGeo 返回客户端地理位置（country_code 等）。
// 任何网络/解析异常均返回 (Info{}, nil)，由调用方按「未知→非目标地区」处理。
func GetGeo(ctx context.Context) (Info, error) {
	c := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, APIURL, nil)
	if err != nil {
		return Info{}, nil
	}
	resp, err := c.Do(req)
	if err != nil {
		return Info{}, nil
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return Info{}, nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return Info{}, nil
	}
	var r Info
	if err := json.Unmarshal(body, &r); err != nil {
		return Info{}, nil
	}
	// 归一化：country_code 转小写；缺失时尝试用 country 名推断。
	r.CountryCode = strings.ToLower(strings.TrimSpace(r.CountryCode))
	if r.CountryCode == "" && strings.EqualFold(r.Country, "China") {
		r.CountryCode = "cn"
	}
	return r, nil
}

// GetCountryCode 返回客户端国家码（小写 alpha-2），如 "cn"。异常时返回空串。
func GetCountryCode(ctx context.Context) (string, error) {
	info, err := GetGeo(ctx)
	if err != nil {
		return "", err
	}
	return info.CountryCode, nil
}

// IsCountry 判断客户端是否位于指定国家（code 为 alpha-2，大小写不敏感）。
func IsCountry(ctx context.Context, code string) (bool, error) {
	cc, err := GetCountryCode(ctx)
	if err != nil {
		return false, err
	}
	return strings.EqualFold(cc, code), nil
}

// IsInChina 便捷方法：判断客户端是否位于中国（country_code == "cn"）。
func IsInChina(ctx context.Context) (bool, error) {
	return IsCountry(ctx, "CN")
}

// WithMirrorFallback 通用兜底：先以原始 URL 执行 do；若失败且原始 URL 为 https，
// 则把 URL 改写为「ChinaMirrorProxy + 原始 URL」后，用独立超时上下文重试一次。
//
// 适用于所有直连 GitHub 易失败的场景（国内网络）：二进制下载、检查更新（GitHub API）等。
// 设计原则：
//   - 仅作「直连失败→镜像重试」的兜底，不阻断主流程；任何失败均透传错误供调用方处理。
//   - 重试使用独立超时上下文，避免复用已（可能）耗尽的父 ctx 截止时间。
//   - do 的签名为 func(ctx, url string) error，由调用方在其中完成具体请求
//     （如下载落盘、HTTP 查询并解析响应等），从而与具体下载器解耦。
func WithMirrorFallback(ctx context.Context, rawURL string, timeout time.Duration, do func(ctx context.Context, url string) error) error {
	if err := do(ctx, rawURL); err != nil {
		if !strings.HasPrefix(rawURL, "https://") {
			return err
		}
		log.Printf("[geo] 直连失败，尝试通过镜像代理重试: %v", err)
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), timeout)
		defer cancel()
		mirrorURL := strings.TrimRight(ChinaMirrorProxy, "/") + "/" + rawURL
		if rerr := do(rctx, mirrorURL); rerr != nil {
			return rerr
		}
	}
	return nil
}
