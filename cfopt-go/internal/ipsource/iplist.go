package ipsource

import (
	"bufio"
	"os"
	"strconv"
	"strings"

	"cfopt/internal/common"
)

// IPListParser 解析 .iplist 格式：IP|延迟|速度|地区码。
type IPListParser struct{}

// Read 解析 .iplist 文件，跳过注释(#)与空行，非法 IP 自动忽略。
func (p *IPListParser) Read(path string) ([]IPRecord, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, common.Wrap("ipsource:iplist:open", err)
	}
	defer f.Close()

	var records []IPRecord
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) < 4 {
			common.Warn("ipsource:iplist 行格式不完整，已跳过", "line", lineNo, "path", path)
			continue
		}
		ip := strings.TrimSpace(parts[0])
		if err := common.ValidateIP(ip); err != nil {
			common.Warn("ipsource:iplist 非法 IP，已跳过", "ip", ip, "line", lineNo)
			continue
		}
		rec := IPRecord{IP: ip, Colo: strings.TrimSpace(parts[3])}
		if v, e := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64); e == nil {
			rec.Latency = v
		}
		if v, e := strconv.ParseFloat(strings.TrimSpace(parts[2]), 64); e == nil {
			rec.Speed = v
		}
		records = append(records, rec)
	}
	if err := scanner.Err(); err != nil {
		return nil, common.Wrap("ipsource:iplist:scan", err)
	}
	return records, nil
}
