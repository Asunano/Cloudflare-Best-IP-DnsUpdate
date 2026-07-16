package ipsource

import (
	"bufio"
	"os"
	"strings"

	"cfopt/internal/common"
)

// TXTParser 解析纯 .txt IP 列表（每行一个 IP，支持 # 注释与空白行）。
type TXTParser struct{}

// Read 解析纯文本 IP 列表，调用 common.ValidateIP 过滤非法项。
func (p *TXTParser) Read(path string) ([]IPRecord, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, common.Wrap("ipsource:txt:open", err)
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
		// 兼容 "IP ..." 或 "IP,..." 形式，仅取首个 token
		fields := strings.Fields(line)
		ip := strings.TrimRight(fields[0], ",")
		if err := common.ValidateIP(ip); err != nil {
			common.Warn("ipsource:txt 非法 IP，已跳过", "ip", ip, "line", lineNo)
			continue
		}
		records = append(records, IPRecord{IP: ip})
	}
	if err := scanner.Err(); err != nil {
		return nil, common.Wrap("ipsource:txt:scan", err)
	}
	return records, nil
}
