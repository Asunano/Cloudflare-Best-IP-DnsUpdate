package cfst

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestMatchCFSTAsset 验证 cfst 资产名匹配逻辑 matchCFSTAsset：
// 必须匹配 cfst_<goos>_<goarch>.{zip|tar.gz}，且排除 _old 变体、排除错误扩展名。
// 注意：架构（amd64/arm64）限制不在本函数内（在 Fetch 的 switch 中），
// 本函数仅做「按平台 + 扩展名」的名称匹配。
func TestMatchCFSTAsset(t *testing.T) {
	cases := []struct {
		name  string
		asset string
		goos  string
		arch  string
		want  bool
	}{
		// 标准匹配
		{"windows_amd64_zip", "cfst_windows_amd64.zip", "windows", "amd64", true},
		{"linux_arm64_targz", "cfst_linux_arm64.tar.gz", "linux", "arm64", true},
		{"darwin_amd64_zip", "cfst_darwin_amd64.zip", "darwin", "amd64", true},

		// _old 变体必须排除（即便平台/扩展名匹配）
		{"old_variant_excluded", "cfst_windows_amd64_old.zip", "windows", "amd64", false},

		// 错误扩展名
		{"wrong_ext_txt", "cfst_windows_amd64.zip.txt", "windows", "amd64", false},
		{"wrong_ext_plain", "cfst_windows_amd64.txt", "windows", "amd64", false},

		// 平台不匹配（即便扩展名正确）
		{"mismatched_goos", "cfst_linux_amd64.zip", "windows", "amd64", false},
		{"mismatched_goarch", "cfst_windows_arm64.zip", "windows", "amd64", false},

		// 名称前缀不符（如多一段）
		{"extra_segment", "cfst_windows_amd64_extra.zip", "windows", "amd64", false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, matchCFSTAsset(c.asset, c.goos, c.arch),
				"matchCFSTAsset(%q, %q, %q)", c.asset, c.goos, c.arch)
		})
	}
}
