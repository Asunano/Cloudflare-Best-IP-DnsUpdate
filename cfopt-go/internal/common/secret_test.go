package common

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestMaskSecret(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"", ""},
		{"ab", "****"},
		{"abcd", "****"},
		{"abcde", "abcd****de"},
		{"cfut_abcdefghij123456", "cfut****56"},
		{"Bearer cfut_abcdefghij123456", "Bearer cfut****56"},
		{"  spaced_token_xyz123  ", "spac****23"},
	}
	for _, c := range cases {
		assert.Equal(t, c.want, MaskSecret(c.in), "MaskSecret(%q)", c.in)
	}
}
