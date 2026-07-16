package common

import (
	"log/slog"
	"os"
	"strings"
)

// logger 为全局结构化日志器（基于 log/slog）。
var logger *slog.Logger

func init() {
	// 默认 INFO 级别，输出到 stderr（与业务解耦，便于 daemon/GUI 重定向）。
	logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
}

// InitLogger 依据 GlobalConfig.LogLevel 初始化全局 slog 日志器。
// 支持: DEBUG, INFO, WARN(WARNING), ERROR（不区分大小写）。
func InitLogger(level string) {
	var lvl slog.Level
	switch normalizeLevel(level) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lvl})
	logger = slog.New(handler)
	slog.SetDefault(logger)
}

// normalizeLevel 将日志级别转为小写，空值回退 info。
func normalizeLevel(level string) string {
	if level == "" {
		return "info"
	}
	return strings.ToLower(level)
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
