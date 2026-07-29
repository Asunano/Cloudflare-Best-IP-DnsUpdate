package common

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRotatingWriter_RotatesAtMaxSize(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "sub", "test.log")

	w, err := newRotatingWriter(logPath, 20) // 小上限便于触发轮转
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	defer w.Close()

	// 首次写入 15 字节，未超阈值，不应轮转。
	if _, err := w.Write([]byte("aaaaaaaaaaaaaaa")); err != nil {
		t.Fatalf("write1: %v", err)
	}
	if _, err := os.Stat(logPath + ".old"); err == nil {
		t.Fatalf("不应在首次未超阈值时轮转")
	}

	// 第二次写入使累计超过 20，触发轮转：旧内容 → .old，新文件重建。
	if _, err := w.Write([]byte("bbbbbbbbbbbbbbb")); err != nil {
		t.Fatalf("write2: %v", err)
	}
	if _, err := os.Stat(logPath + ".old"); err != nil {
		t.Fatalf("应已生成 .old: %v", err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read new: %v", err)
	}
	if !strings.Contains(string(data), "bbbbbbbbbbbbbbb") {
		t.Fatalf("新文件内容错误: %q", string(data))
	}
	if strings.Contains(string(data), "aaaaaaaaaaaaaaa") {
		t.Fatalf("新文件不应含旧内容: %q", string(data))
	}
}

// captureHandler 仅收集属性，供测试 redactHandler 脱敏效果。
type captureHandler struct {
	mu    sync.Mutex
	attrs []slog.Attr
}

func (c *captureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (c *captureHandler) Handle(_ context.Context, r slog.Record) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	r.Attrs(func(a slog.Attr) bool {
		c.attrs = append(c.attrs, a)
		return true
	})
	return nil
}
func (c *captureHandler) WithAttrs(a []slog.Attr) slog.Handler { return c }
func (c *captureHandler) WithGroup(string) slog.Handler       { return c }

func (c *captureHandler) find(key string) (slog.Attr, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, a := range c.attrs {
		if a.Key == key {
			return a, true
		}
	}
	return slog.Attr{}, false
}

func TestRedactHandler_MasksSecretKeys(t *testing.T) {
	cap := &captureHandler{}
	h := redactHandler{inner: cap}
	r := slog.NewRecord(time.Now(), slog.LevelInfo, "sync", 0)
	r.AddAttrs(
		slog.String("cf_token", "cfut_abcdefghij123456"),
		slog.String("dnspod_secret_key", "sk-verylongsecretvalue123456"),
		slog.String("domain", "example.com"),
		slog.String("Authorization", "Bearer tok_supersecretvalue99"),
	)
	require.NoError(t, h.Handle(context.Background(), r))

	tok, ok := cap.find("cf_token")
	require.True(t, ok)
	assert.Equal(t, "cfut****56", tok.Value.String())

	key, ok := cap.find("dnspod_secret_key")
	require.True(t, ok)
	assert.Equal(t, "sk-v****56", key.Value.String())

	// 普通属性不脱敏
	dom, ok := cap.find("domain")
	require.True(t, ok)
	assert.Equal(t, "example.com", dom.Value.String())

	// Bearer 前缀值脱敏
	auth, ok := cap.find("Authorization")
	require.True(t, ok)
	assert.Equal(t, "Bearer tok_****99", auth.Value.String())
}
