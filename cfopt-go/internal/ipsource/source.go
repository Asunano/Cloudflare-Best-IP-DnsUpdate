// Package ipsource 提供多格式 IP 数据源解析：
// .iplist（IP|延迟|速度|地区码）、cfst .csv、纯 .txt IP 列表。
// 所有解析器均复用 common.ValidateIP 作为唯一 IP 校验入口。
package ipsource

import (
	"path/filepath"
	"strings"

	"cfopt/internal/common"
)

// IPRecord 表示一条优选 IP 记录。
type IPRecord struct {
	IP      string  `json:"ip"`
	Latency float64 `json:"latency"`
	Speed   float64 `json:"speed"`
	Colo    string  `json:"colo"`
}

// IPSource 是多格式 IP 源解析接口。
type IPSource interface {
	Read(path string) ([]IPRecord, error)
}

// AutoSource 根据扩展名/表头自动选择解析器。
type AutoSource struct{}

// NewAutoSource 返回自动探测格式的解析器。
func NewAutoSource() *AutoSource { return &AutoSource{} }

// Read 自动探测文件格式并解析。
func (a *AutoSource) Read(path string) ([]IPRecord, error) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".iplist":
		return (&IPListParser{}).Read(path)
	case ".csv":
		return (&CSVParser{}).Read(path)
	case ".txt":
		return (&TXTParser{}).Read(path)
	default:
		// 无扩展名或未知：按纯文本处理（容错）
		return (&TXTParser{}).Read(path)
	}
}

// Read 包级便捷函数：自动探测并解析 path。
func Read(path string) ([]IPRecord, error) {
	records, err := NewAutoSource().Read(path)
	if err != nil {
		return nil, common.Wrap("ipsource:read", err)
	}
	return records, nil
}

// 编译期接口实现断言。
var (
	_ IPSource = (*AutoSource)(nil)
	_ IPSource = (*IPListParser)(nil)
	_ IPSource = (*CSVParser)(nil)
	_ IPSource = (*TXTParser)(nil)
)
