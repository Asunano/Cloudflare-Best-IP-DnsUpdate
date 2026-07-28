package dns

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"cfopt/internal/common"
	"cfopt/internal/config"
)

// dnspodManagedState 记录本域名下「cfopt 曾管理的线路 → 子域名」映射，
// 用于在用户从 isp_lines/多线路切回单线路或删减线路时，回收不再配置的孤儿 DNS 记录。
// 仅清理 cfopt 自身此前创建并跟踪的记录，避免误删用户手动添加的其它记录。
type dnspodManagedState struct {
	Domain string            `json:"domain"`
	Lines  map[string]string `json:"lines"` // line -> subdomain（per-line 子域名）
}

// sanitizeFilename 将域名转为安全文件名（仅保留字母数字与 . - _，其余替换为 _）。
func sanitizeFilename(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	return b.String()
}

// dnspodStatePath 返回某域名的托管状态文件路径：<dataDir>/dnspod/<domain>.managed.json。
func dnspodStatePath(dataDir, domain string) string {
	return filepath.Join(dataDir, "dnspod", sanitizeFilename(domain)+".managed.json")
}

// loadDNSPodState 读取托管状态；文件不存在或解析失败返回 (nil, err)。
func loadDNSPodState(path string) (*dnspodManagedState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var st dnspodManagedState
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, err
	}
	if st.Lines == nil {
		st.Lines = map[string]string{}
	}
	return &st, nil
}

// saveDNSPodState 持久化托管状态（确保父目录存在）。
func saveDNSPodState(path string, st *dnspodManagedState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ResolveDataDir 从全局配置解析数据目录；为空回退 ./assets/data。导出供 cmd 层复用。
func ResolveDataDir(cfg *config.Config) string {
	if cfg != nil && cfg.Global != nil && cfg.Global.DataDir != "" {
		return cfg.Global.DataDir
	}
	return "./assets/data"
}

// cleanupOrphanLines 回收不再配置的线路对应的 DNS 记录。
// 仅处理「此前由 cfopt 管理（已持久化）且当前 Lines() 不再包含」的线路，
// 删除其 per-line 子域名下、RecordLine=该线路的 A 记录。这些记录由 cfopt 创建并跟踪，
// 故回收是安全的；删除前按 DeleteMode 守卫（none 不删，保持与 SyncMultiLine 一致）。
func (p *DNSPodProvider) cleanupOrphanLines(ctx context.Context, resv LineResolver, res *SyncResult) {
	if p.dataDir == "" {
		return
	}
	path := dnspodStatePath(p.dataDir, p.domain)

	// 当前管理的线路集合（line -> subdomain）。
	current := map[string]string{}
	for _, line := range resv.Lines() {
		current[line] = resv.ResolveSubDomain(line)
	}

	prev, err := loadDNSPodState(path)
	if err != nil {
		// 首次运行或读取失败：仅写入当前状态，不做清理。
		_ = saveDNSPodState(path, &dnspodManagedState{Domain: p.domain, Lines: current})
		return
	}

	var removed []string
	for line := range prev.Lines {
		if _, ok := current[line]; !ok {
			removed = append(removed, line)
		}
	}
	if len(removed) == 0 {
		_ = saveDNSPodState(path, &dnspodManagedState{Domain: p.domain, Lines: current})
		return
	}
	sort.Strings(removed)

	for _, line := range removed {
		sub := prev.Lines[line]
		common.Info("dnspod: 清理孤儿线路记录", "line", line, "sub", sub)
		records, lerr := p.ListLineRecords(ctx, p.domain, sub, line)
		if lerr != nil {
			res.Errors = append(res.Errors, "dnspod:orphan:"+line+": list: "+lerr.Error())
			continue
		}
		for _, rec := range records {
			if derr := p.DeleteLineRecord(ctx, p.domain, rec.ID); derr != nil {
				res.Errors = append(res.Errors, "dnspod:orphan:"+line+": delete: "+derr.Error())
				continue
			}
			res.Deleted++
		}
	}

	_ = saveDNSPodState(path, &dnspodManagedState{Domain: p.domain, Lines: current})
}
