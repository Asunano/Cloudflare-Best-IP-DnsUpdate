// Package sync 编排「测速 → 提取最优 IP → 同步 CF/DNSPod → 写入历史」主链路，
// 并提供多格式 IP 列表互转工具（复用 ipsource 解析器）。
package sync

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// ExtractBestIPs 从测速结果筛选最优 N 个 IP：先按速度降序，再按延迟升序。
// n<=0 时返回全部（仍按序）。返回 []IPRecord 供 DNS 同步使用。
func ExtractBestIPs(results []speedtest.SpeedResult, n int) []ipsource.IPRecord {
	recs := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		recs = append(recs, ipsource.IPRecord{
			IP:      r.IP,
			Latency: r.Latency,
			Speed:   r.Speed,
			Colo:    r.Colo,
		})
	}
	sort.SliceStable(recs, func(i, j int) bool {
		if recs[i].Speed != recs[j].Speed {
			return recs[i].Speed > recs[j].Speed
		}
		return recs[i].Latency < recs[j].Latency
	})
	if n > 0 && len(recs) > n {
		recs = recs[:n]
	}
	return recs
}

// WriteIPList 将 IPRecord 列表写入 .iplist 文件（格式：IP|延迟|速度|地区码），自动创建父目录。
// 写入前若路径扩展名非 .iplist 则强制改写为 .iplist（保留目录与基名），防止 .txt 被误解析为优选结果。
func WriteIPList(records []ipsource.IPRecord, path string) error {
	if ext := filepath.Ext(path); ext != ".iplist" {
		base := strings.TrimSuffix(path, ext)
		path = base + ".iplist"
	}
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return common.Wrap("sync:writeiplist:mkdir", err)
		}
	}
	f, err := os.Create(path)
	if err != nil {
		return common.Wrap("sync:writeiplist:create", err)
	}
	defer func() { _ = f.Close() }()

	w := bufio.NewWriter(f)
	now := time.Now().Format("2006-01-02 15:04:05")
	_, _ = w.WriteString("# Cloudflare 优选 IP 列表\n")
	_, _ = w.WriteString("# 生成时间: " + now + "\n")
	_, _ = w.WriteString("#\n")
	_, _ = w.WriteString("# IP地址|延迟(ms)|下载速度(MB/s)|地区码\n")
	for _, r := range records {
		line := fmt.Sprintf("%s|%s|%s|%s\n", r.IP, formatFloat(r.Latency), formatFloat(r.Speed), r.Colo)
		_, _ = w.WriteString(line)
	}
	if err := w.Flush(); err != nil {
		return common.Wrap("sync:writeiplist:flush", err)
	}
	return nil
}

// CSVToIPList 读取 cfst .csv 文件，返回 IPRecord 列表（复用 ipsource.CSVParser）。
func CSVToIPList(path string) ([]ipsource.IPRecord, error) {
	recs, err := (&ipsource.CSVParser{}).Read(path)
	if err != nil {
		return nil, common.Wrap("sync:csv2iplist", err)
	}
	return recs, nil
}

// IPListToTxt 将 .iplist 文件转换为纯 IP 列表 .txt（仅第一列）。
func IPListToTxt(iplistPath, txtPath string) error {
	recs, err := (&ipsource.IPListParser{}).Read(iplistPath)
	if err != nil {
		return common.Wrap("sync:iplist2txt:read", err)
	}
	return writeTxt(ipList(recs), txtPath)
}

// TxtToIPList 将纯 IP .txt 转换为 .iplist（延迟/速度默认 0，地区码默认 UNKNOWN）。
func TxtToIPList(txtPath, iplistPath string) error {
	recs, err := (&ipsource.TXTParser{}).Read(txtPath)
	if err != nil {
		return common.Wrap("sync:txt2iplist:read", err)
	}
	for i := range recs {
		if recs[i].Colo == "" {
			recs[i].Colo = "UNKNOWN"
		}
	}
	return WriteIPList(recs, iplistPath)
}

// DetectAndConvert 自动探测源文件格式并转换为目标格式（依据扩展名：csv/iplist/txt）。
// 同格式则直接复制；不支持的转换返回错误。
func DetectAndConvert(src, dst string) error {
	srcFmt := detectFormat(src)
	dstFmt := detectFormat(dst)
	if srcFmt == "" || dstFmt == "" {
		return common.New("sync:detect", "无法识别文件格式: "+src+" -> "+dst)
	}
	if srcFmt == dstFmt {
		data, err := os.ReadFile(src)
		if err != nil {
			return common.Wrap("sync:detect:read", err)
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return common.Wrap("sync:detect:mkdir", err)
		}
		if err := os.WriteFile(dst, data, 0o644); err != nil {
			return common.Wrap("sync:detect:write", err)
		}
		return nil
	}
	switch srcFmt + "-" + dstFmt {
	case "csv-iplist":
		recs, err := CSVToIPList(src)
		if err != nil {
			return err
		}
		return WriteIPList(recs, dst)
	case "iplist-txt":
		return IPListToTxt(src, dst)
	case "txt-iplist":
		return TxtToIPList(src, dst)
	default:
		return common.New("sync:detect", "不支持的转换: "+srcFmt+" -> "+dstFmt)
	}
}

// ---- 内部辅助 ----

func ipList(recs []ipsource.IPRecord) []string {
	out := make([]string, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.IP)
	}
	return out
}

func writeTxt(ips []string, path string) error {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return common.Wrap("sync:writetxt:mkdir", err)
		}
	}
	f, err := os.Create(path)
	if err != nil {
		return common.Wrap("sync:writetxt:create", err)
	}
	defer func() { _ = f.Close() }()
	w := bufio.NewWriter(f)
	for _, ip := range ips {
		_, _ = w.WriteString(ip + "\n")
	}
	return common.Wrap("sync:writetxt:flush", w.Flush())
}

func detectFormat(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".csv":
		return "csv"
	case ".iplist":
		return "iplist"
	case ".txt":
		return "txt"
	default:
		return ""
	}
}

func formatFloat(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64)
}
