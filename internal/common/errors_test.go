package common

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestCFOptError_New 验证 New 构造的纯业务错误。
func TestCFOptError_New(t *testing.T) {
	err := New("config:load", "文件缺失")
	require.Error(t, err)

	var ce *CFOptError
	require.True(t, errors.As(err, &ce), "应为 *CFOptError")
	assert.Equal(t, "config:load", ce.Op)
	assert.Contains(t, err.Error(), "config:load")
	assert.Contains(t, err.Error(), "文件缺失")
}

// TestCFOptError_Unwrap 验证 Error() 与 Unwrap() 链，errors.Is 可穿透。
func TestCFOptError_Unwrap(t *testing.T) {
	base := errors.New("connection refused")
	err := Wrap("dns:list", base)
	require.Error(t, err)

	assert.Contains(t, err.Error(), "dns:list")
	assert.Contains(t, err.Error(), "connection refused")

	// Unwrap 应返回底层错误，errors.Is 可穿透。
	assert.True(t, errors.Is(err, base), "errors.Is 应穿透到 base 错误")

	var ce *CFOptError
	require.True(t, errors.As(err, &ce))
	assert.Equal(t, base, ce.Unwrap())
}

// TestCFOptError_WrapNil 验证 Wrap(nil) 返回 nil，便于 `return common.Wrap(...)` 透传。
func TestCFOptError_WrapNil(t *testing.T) {
	assert.Nil(t, Wrap("op", nil))
}

// TestCFOptError_WrapChain 验证多级 Wrap 链仍可逐层 Unwrap。
func TestCFOptError_WrapChain(t *testing.T) {
	root := errors.New("root cause")
	level1 := Wrap("layer1", root)
	level2 := Wrap("layer2", level1)

	assert.True(t, errors.Is(level2, root), "多层 Wrap 后 errors.Is 仍能命中 root")
	assert.Contains(t, level2.Error(), "layer2")
	assert.Contains(t, level2.Error(), "layer1")
	assert.Contains(t, level2.Error(), "root cause")
}

// TestCFOptError_FormatVerb 验证 %w 风格格式化与 Error() 一致。
func TestCFOptError_FormatVerb(t *testing.T) {
	err := Wrap("op", fmt.Errorf("boom"))
	assert.Equal(t, "cfopt: op: boom", err.Error())
}
