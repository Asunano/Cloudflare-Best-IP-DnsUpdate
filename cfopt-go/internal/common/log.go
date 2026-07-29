package common

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// logger 为全局结构化日志器（基于 log/slog）。
var logger *slog.Logger

func init() {
	// 默认 INFO 级别，输出到 stderr（与业务解耦，便于 daemon/GUI 重定向）。
	// 经 redactHandler 包裹，落盘的 token/secret 等敏感属性值自动脱敏。
	logger = slog.New(redactHandler{inner: slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})})
	slog.SetDefault(logger)
}

// secretKeyWords 命中这些 key（不区分大小写）的属性值将被脱敏。
var secretKeyWords = []string{"token", "secret", "password", "passwd", "apikey", "api_key", "key"}

// redactHandler 包裹底层 slog.Handler，在输出前对敏感属性值脱敏，
// 等价于 Bash 原版 sanitize_log：任何经结构化日志打印的 token/secret 都不会以明文落盘。
type redactHandler struct {
	inner slog.Handler
}

func (h redactHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

// Handle 克隆记录并对各属性脱敏后交给底层 handler。
func (h redactHandler) Handle(ctx context.Context, r slog.Record) error {
	nr := slog.NewRecord(r.Time, r.Level, r.Message, r.PC)
	r.Attrs(func(a slog.Attr) bool {
		nr.AddAttrs(redactAttr(a))
		return true
	})
	return h.inner.Handle(ctx, nr)
}

// WithAttrs 带属性创建新 handler，属性同样先脱敏。
func (h redactHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	redacted := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		redacted[i] = redactAttr(a)
	}
	return redactHandler{inner: h.inner.WithAttrs(redacted)}
}

// WithGroup 带分组创建新 handler。
func (h redactHandler) WithGroup(name string) slog.Handler {
	return redactHandler{inner: h.inner.WithGroup(name)}
}

// redactAttr 对单个属性脱敏：key 命中敏感词，或值形如 "Bearer <token>" 时脱敏其值。
func redactAttr(a slog.Attr) slog.Attr {
	if a.Value.Kind() != slog.KindString {
		return a
	}
	key := strings.ToLower(a.Key)
	for _, w := range secretKeyWords {
		if strings.Contains(key, w) {
			a.Value = slog.StringValue(MaskSecret(a.Value.String()))
			return a
		}
	}
	v := a.Value.String()
	if strings.HasPrefix(v, "Bearer ") {
		a.Value = slog.StringValue(MaskSecret(v))
	}
	return a
}

// InitLogger 依据 level 初始化全局 slog 日志器。
// logFile 非空时，日志会同时写入该文件（按 10MB 轮转，旧文件落为 <logFile>.old），
// 与 Bash 原版「每模块写 logs/<module>/ 并 10MB 轮转」对齐，弥补 Go 版原先仅 stderr 无落盘的问题。
// logFile 为空则仅输出到 stderr。文件不可用（如权限不足）时静默退回仅 stderr，不影响主流程。
func InitLogger(level, logFile string) {
	lvl := normalizeLevel(level)

	var out io.Writer = os.Stderr
	if logFile != "" {
		if rw, err := newRotatingWriter(logFile, 10*1024*1024); err == nil {
			out = io.MultiWriter(os.Stderr, rw)
		}
	}

	handler := slog.NewTextHandler(out, &slog.HandlerOptions{Level: lvl})
	logger = slog.New(redactHandler{inner: handler})
	slog.SetDefault(logger)
}

// normalizeLevel 将日志级别转为小写，空值回退 info。
func normalizeLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// log 统一入口，确保 logger 非空（防止未初始化时 panic）。
func log() *slog.Logger {
	if logger == nil {
		return slog.Default()
	}
	return logger
}

// Info 输出 INFO 级别结构化日志。args 为 key-value 对。
func Info(msg string, args ...any) { log().Info(msg, args...) }

// Warn 输出 WARN 级别结构化日志。
func Warn(msg string, args ...any) { log().Warn(msg, args...) }

// Error 输出 ERROR 级别结构化日志。
func Error(msg string, args ...any) { log().Error(msg, args...) }

// Debug 输出 DEBUG 级别结构化日志。
func Debug(msg string, args ...any) { log().Debug(msg, args...) }

// rotatingWriter 按大小轮转的文件写入器：超过 maxSize 时将当前文件重命名为 <path>.old 并新建。
// 仅保留一个历史文件（与 Bash 原版 rotate_log 行为一致），避免无限增长。
type rotatingWriter struct {
	path    string
	maxSize int64
	mu      sync.Mutex
	f       *os.File
	size    int64
}

// newRotatingWriter 创建轮转写入器，必要时创建父目录并打开文件。
func newRotatingWriter(path string, maxSize int64) (*rotatingWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	w := &rotatingWriter{path: path, maxSize: maxSize}
	if err := w.open(); err != nil {
		return nil, err
	}
	return w, nil
}

// open 打开（或重建）日志文件并刷新当前大小。
func (w *rotatingWriter) open() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	w.f = f
	if fi, err := f.Stat(); err == nil {
		w.size = fi.Size()
	} else {
		w.size = 0
	}
	return nil
}

// Write 写入日志；超过 maxSize 时先轮转（当前文件 → .old），再写入新文件。
func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	if w.size+int64(len(p)) > w.maxSize {
		_ = w.f.Close()
		old := w.path + ".old"
		_ = os.Remove(old)
		if err := os.Rename(w.path, old); err == nil {
			w.size = 0
		}
		// 重命名失败则继续追加当前文件，不中断主流程。
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	n, err := w.f.Write(p)
	w.size += int64(n)
	return n, err
}

// Close 关闭底层文件。
func (w *rotatingWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f != nil {
		return w.f.Close()
	}
	return nil
}
