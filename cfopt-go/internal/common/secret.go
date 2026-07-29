package common

import "strings"

// MaskSecret 对敏感字符串做脱敏：保留前 4 后 2，中间以 **** 替代；
// 长度 ≤4 整体替换为 ****；兼容 "Bearer <token>" 形式（仅脱敏 token 部分）。
// 用于日志兜底与显式打印凭证时避免泄露完整密钥（对应 Bash 原版 sanitize_log 语义）。
func MaskSecret(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	const prefix = "Bearer "
	if strings.HasPrefix(s, prefix) {
		return prefix + MaskSecret(strings.TrimPrefix(s, prefix))
	}
	if len(s) <= 4 {
		return "****"
	}
	return s[:4] + "****" + s[len(s)-2:]
}
