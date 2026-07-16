package common

import (
	"fmt"
	"strconv"
	"strings"
)

// ValidateIP 校验 IPv4 地址格式与合法性，是全工程唯一的 IP 校验入口，
// 测速与 DNS 同步均调用它。
//
// 拒绝以下情况：
//   - 格式非法（段数 ≠ 4，或某段非数字）
//   - 某段超出 0-255 范围
//   - 0.0.0.0（无效地址）
//   - 255.255.255.255（广播地址）
func ValidateIP(s string) error {
	s = strings.TrimSpace(s)
	if s == "" {
		return fmt.Errorf("cfopt: 空 IP 地址")
	}
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return fmt.Errorf("cfopt: IP 格式非法: %q", s)
	}
	for _, p := range parts {
		if p == "" {
			return fmt.Errorf("cfopt: IP 段为空: %q", s)
		}
		v, err := strconv.Atoi(p)
		if err != nil {
			return fmt.Errorf("cfopt: IP 段非数字: %q", s)
		}
		if v < 0 || v > 255 {
			return fmt.Errorf("cfopt: IP 段超出范围(0-255): %q", s)
		}
	}
	// 拒绝特殊地址
	if s == "0.0.0.0" || s == "255.255.255.255" {
		return fmt.Errorf("cfopt: 拒绝特殊地址: %q", s)
	}
	return nil
}
