package dns

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"time"

	"github.com/cenkalti/backoff/v4"

	"cfopt/internal/common"
)

// HTTPClient 共享 HTTP 客户端，封装统一重试 + 指数退避。
// Cloudflare 与 DNSPod 共用，避免重复实现传输层逻辑。
type HTTPClient struct {
	client *http.Client
}

// NewHTTPClient 构造共享 HTTP 客户端（timeout<=0 时默认 10s）。
func NewHTTPClient(timeout time.Duration) *HTTPClient {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &HTTPClient{client: &http.Client{Timeout: timeout}}
}

// DoRequest 执行 HTTP 请求并返回响应体、状态码。
//
// 重试策略（指数退避，基于 cenkalti/backoff/v4）：
//   - 429 限流 / 5xx 服务端错误 / 网络错误：可重试
//   - 401 / 403 认证错误：不重试（返回 backoff.Permanent 错误）
//   - 2xx：成功
func (c *HTTPClient) DoRequest(ctx context.Context, method, url string, body []byte, headers map[string]string) ([]byte, int, error) {
	var (
		respBody []byte
		status   int
	)

	operation := func() error {
		var reqBody io.Reader
		if body != nil {
			reqBody = bytes.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, url, reqBody)
		if err != nil {
			return backoff.Permanent(common.Wrap("http:newrequest", err))
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		if body != nil && req.Header.Get("Content-Type") == "" {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := c.client.Do(req)
		if err != nil {
			// 网络错误：可重试
			return common.Wrap("http:do", err)
		}
		defer resp.Body.Close()

		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return common.Wrap("http:read", err)
		}
		status = resp.StatusCode
		respBody = data

		switch {
		case status == http.StatusUnauthorized || status == http.StatusForbidden:
			// 认证错误：不重试
			return backoff.Permanent(common.New("http:auth", "认证失败"))
		case status == http.StatusTooManyRequests || status >= 500:
			// 限流 / 服务端错误：可重试
			return common.New("http:retry", "服务端错误")
		default:
			return nil
		}
	}

	exp := backoff.NewExponentialBackOff()
	exp.InitialInterval = 500 * time.Millisecond
	exp.MaxElapsedTime = 30 * time.Second
	if err := backoff.Retry(operation, backoff.WithContext(exp, ctx)); err != nil {
		return respBody, status, err
	}
	return respBody, status, nil
}
