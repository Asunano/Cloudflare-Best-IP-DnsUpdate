// Package common 提供 cfopt 全工程共享的基础设施：
// 统一错误类型、结构化日志（slog）、IP 校验、跨平台进程锁、文件工具。
// 该包不依赖任何业务包，零业务依赖，供 internal/ 下所有领域包复用。
package common

import "fmt"

// CFOptError 是 cfopt 统一的错误类型，携带操作名(Op)与底层错误(Err)。
// 跨包错误统一用 `fmt.Errorf("cfopt: %w", err)` 包裹，便于 errors.Is/As 链追踪。
type CFOptError struct {
	Op  string
	Err error
}

// Error 实现 error 接口。
func (e *CFOptError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("cfopt: %s: %v", e.Op, e.Err)
	}
	return fmt.Sprintf("cfopt: %s", e.Op)
}

// Unwrap 支持 errors.Is / errors.As 与 %w 链。
func (e *CFOptError) Unwrap() error {
	return e.Err
}

// New 构造一个不带底层错误的 CFOptError（用于纯业务错误，如参数校验失败）。
func New(op, msg string) error {
	return &CFOptError{Op: op, Err: fmt.Errorf("%s", msg)}
}

// Wrap 将底层错误包装为 CFOptError，遵循 `fmt.Errorf("cfopt: %w", err)` 约定。
// err 为 nil 时返回 nil，方便 `return common.Wrap(...)` 直接透传。
func Wrap(op string, err error) error {
	if err == nil {
		return nil
	}
	return &CFOptError{Op: op, Err: err}
}
