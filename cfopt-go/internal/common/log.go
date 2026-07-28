package common

import (
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
	logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
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
	logger = slog.New(handler)
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
