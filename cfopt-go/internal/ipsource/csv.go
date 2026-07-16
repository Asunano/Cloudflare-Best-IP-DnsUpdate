package ipsource

import (
	"encoding/csv"
	"os"
	"strconv"
	"strings"

	"cfopt/internal/common"
)

// CSVParser 解析 cfst 生成的 .csv：
// IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码
type CSVParser struct{}

// Read 解析 cfst CSV 文件，首行若为表头("IP")则跳过。
func (p *CSVParser) Read(path string) ([]IPRecord, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, common.Wrap("ipsource:csv:open", err)
	}
	defer f.Close()

	reader := csv.NewReader(f)
	reader.FieldsPerRecord = -1 // 允许不定长行
	reader.LazyQuotes = true
	reader.TrimLeadingSpace = true

	rows, err := reader.ReadAll()
	if err != nil {
		return nil, common.Wrap("ipsource:csv:read", err)
	}

	var records []IPRecord
	for i, row := range rows {
		if i == 0 && len(row) > 0 && strings.EqualFold(strings.TrimSpace(row[0]), "ip") {
			continue // 表头
		}
		if len(row) < 7 {
			continue
		}
		ip := strings.TrimSpace(row[0])
		if err := common.ValidateIP(ip); err != nil {
			continue
		}
		rec := IPRecord{IP: ip, Colo: strings.TrimSpace(row[6])}
		if v, e := strconv.ParseFloat(strings.TrimSpace(row[4]), 64); e == nil {
			rec.Latency = v
		}
		if v, e := strconv.ParseFloat(strings.TrimSpace(row[5]), 64); e == nil {
			rec.Speed = v
		}
		records = append(records, rec)
	}
	return records, nil
}
