package common

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestValidateIP 覆盖合法 IP 放行、拒绝 0.0.0.0 / 255.255.255.255 / 非 IP 字符串。
func TestValidateIP(t *testing.T) {
	valid := []string{
		"1.1.1.1",
		"192.168.1.1",
		"255.255.255.254",
		"0.0.0.1",
		"10.0.0.0",
		"8.8.8.8",
		"1.2.3.4",
		"  9.9.9.9  ", // 前后空白应被 TrimSpace 处理
	}

	for _, ip := range valid {
		assert.NoError(t, ValidateIP(ip), "期望合法 IP 通过: %q", ip)
	}

	invalid := []string{
		"",                 // 空
		"   ",              // 仅空白
		"0.0.0.0",          // 无效地址
		"255.255.255.255",  // 广播地址
		"1.2.3",            // 段数不足
		"1.2.3.4.5",        // 段数过多
		"a.b.c.d",          // 全非数字
		"1.2.3.x",          // 末段非数字
		"256.1.1.1",        // 超出 255
		"-1.1.1.1",         // 负数段
		"1.2.3.999",        // 超出 255
		"1.2.3. 4",         // 段内含空白
		"1..3.4",           // 空段
	}

	for _, ip := range invalid {
		assert.Error(t, ValidateIP(ip), "期望拒绝非法 IP: %q", ip)
	}
}
