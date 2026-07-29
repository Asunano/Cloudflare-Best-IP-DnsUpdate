package dns

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/ipsource"
)

// IP 源文件前置检测默认值（对应 Bash cf-dns/core.sh）。
const (
	// DefaultIPStaleThreshold IP 源文件超过此时长未更新视为过期（默认 48h）。
	DefaultIPStaleThreshold = 48 * time.Hour
	// DefaultIPCountChangeWarnRatio IP 数量相对上次的变动比例超过此值即发严重警告（默认 0.5=50%）。
	DefaultIPCountChangeWarnRatio = 0.5
)

// IPSourceCheckOpts 控制 IP 源文件前置检测行为。零值字段回落到默认值。
type IPSourceCheckOpts struct {
	StaleThreshold       time.Duration // 过期阈值，默认 DefaultIPStaleThreshold
	CountChangeWarnRatio float64       // 数量变化告警比例，默认 DefaultIPCountChangeWarnRatio
}

func (o IPSourceCheckOpts) norm() IPSourceCheckOpts {
	if o.StaleThreshold <= 0 {
		o.StaleThreshold = DefaultIPStaleThreshold
	}
	if o.CountChangeWarnRatio <= 0 {
		o.CountChangeWarnRatio = DefaultIPCountChangeWarnRatio
	}
	return o
}

// CheckIPSources 对一组 IP 源文件做前置检测（对应 Bash cf-dns/core.sh 的时效性与数量变化检测）：
//  1. 时效性：文件 mtime 距现在超过 StaleThreshold → 警告（不阻断，继续更新）。
//  2. 数量变化：解析有效 IP 数，与 <file>.count 侧车对比；变化超过 CountChangeWarnRatio
//     发出严重警告；不论是否变化都更新 <file>.count 为本次数量（供下次对比）。
//
// 返回警告列表（始终非 nil）。调用方应将其并入 SyncResult.Warnings 并日志输出。
// 文件缺失/读取失败等由模块自身读取逻辑报错，此处静默跳过（仅记录 debug）。
func CheckIPSources(files []string, opts IPSourceCheckOpts) []string {
	opts = opts.norm()
	var warns []string
	now := time.Now()
	for _, f := range files {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		fi, err := os.Stat(f)
		if err != nil {
			common.Debug("dns: IP 源文件检测跳过（不存在）", "file", f)
			continue
		}

		// 1. 时效性检测（防止使用陈旧 IP 更新 DNS）。
		age := now.Sub(fi.ModTime())
		if age >= opts.StaleThreshold {
			h := int(age.Hours())
			w := fmt.Sprintf("[WARN] IP 数据已过期 (%d 小时前更新)，建议重新测速；将尝试继续更新", h)
			warns = append(warns, w)
			common.Warn("dns: IP 源文件已过期", "file", f, "age_hours", h)
		}

		// 2. IP 数量变化检测（与上次执行对比）。
		recs, rerr := ipsource.Read(f)
		if rerr != nil {
			common.Debug("dns: IP 源文件数量检测跳过（读取失败）", "file", f, "err", rerr.Error())
			continue
		}
		n := len(recs)
		countFile := f + ".count"
		if prev, perr := readCountFile(countFile); perr == nil {
			if prev > 0 {
				diff := n - prev
				if diff != 0 {
					changePct := absInt(diff) * 100 / prev
					if changePct > int(opts.CountChangeWarnRatio*100) {
						w := fmt.Sprintf("[WARN] 严重警告: IP 数量变化超过 50%% (%d → %d, 变化 %d%%)，请检查测速软件", prev, n, changePct)
						warns = append(warns, w)
						common.Warn("dns: IP 数量变化超过阈值", "file", f, "prev", prev, "now", n, "pct", changePct)
					} else if diff < 0 {
						common.Info("dns: IP 数量减少", "file", f, "prev", prev, "now", n)
					} else {
						common.Info("dns: IP 数量增加", "file", f, "prev", prev, "now", n)
					}
				}
			}
		}
		// 更新本次数量（不论是否变化），供下次对比。
		_ = writeCountFile(countFile, n)
	}
	return warns
}

// readCountFile 读取 <file>.count 侧车中记录的上次 IP 数量。
// 文件不存在/非数字时返回 (0, err)；调用方据此跳过对比、仅写入新值。
func readCountFile(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(data)))
}

// writeCountFile 将本次 IP 数量写入 <file>.count 侧车（确保父目录存在）。
func writeCountFile(path string, n int) error {
	if dir := filepath.Dir(path); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	return os.WriteFile(path, []byte(strconv.Itoa(n)), 0o644)
}
