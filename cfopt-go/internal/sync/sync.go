package sync

import (
	"context"
	"fmt"
	"strings"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/dns"
	"cfopt/internal/history"
	"cfopt/internal/ipsource"
	"cfopt/internal/speedtest"
)

// Syncer 编排「测速 → 提取最优 IP → 同步 CF/DNSPod → 写入历史」主链路。
//
// providers 需包含键：
//   - "cf"      : *dns.CloudflareProvider
//   - "dnspod"  : *dns.DNSPodProvider
//
// 由于两个 Provider 的 Sync 方法配置参数类型不同（*config.CFDNSConfig / *config.DNSPodConfig），
// 无法统一进 DNSProvider 接口，故此处用 map 持有并以类型断言调用具体实现（详见设计 §T7）。
type Syncer struct {
	tester    speedtest.SpeedTester
	providers map[string]dns.DNSProvider
	history   history.HistoryStore
}

// NewSyncer 构造 Syncer。providers 需包含 "cf" 与 "dnspod" 两个键。
func NewSyncer(tester speedtest.SpeedTester, providers map[string]dns.DNSProvider, hist history.HistoryStore) *Syncer {
	return &Syncer{tester: tester, providers: providers, history: hist}
}

// BuildSyncerFromConfig 从配置构造 Syncer（自动构建 CFSTTester 与启用中的 Provider）。
func BuildSyncerFromConfig(cfg *config.Config, hist history.HistoryStore) (*Syncer, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}
	if cfg.CFIP == nil {
		return nil, common.New("sync:build", "缺少 cf-ip 配置（测速器需要）")
	}
	tester, err := speedtest.NewCFSTTester(cfg.CFIP)
	if err != nil {
		return nil, common.Wrap("sync:build:tester", err)
	}
	providers := map[string]dns.DNSProvider{}
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		providers["cf"] = dns.NewCloudflareProvider(cfg.CFDNS)
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		providers["dnspod"] = dns.NewDNSPodProvider(cfg.DNSPod)
	}
	return NewSyncer(tester, providers, hist), nil
}

// SyncSummary 汇总一次 SyncAll 的执行结果，供 CLI/GUI 展示与历史记录。
// JSON 标签使用 snake_case，与 IPC 协议（GUI/Rust sidecar）约定一致。
type SyncSummary struct {
	BestIPCount int      `json:"best_ip_count"` // 提取到的最优 IP 数量
	Updated     int      `json:"updated"`       // 各 Provider 累计更新的记录数
	Created     int      `json:"created"`       // 各 Provider 累计新建的记录数
	Deleted     int      `json:"deleted"`       // 各 Provider 累计删除的记录数
	Errors      []string `json:"errors"`        // 各阶段累积的错误描述
}

// ProgressFunc 进度回调：phase 为阶段名，cur/total 为已完成/总阶段计数。
type ProgressFunc func(phase string, cur, total int)

// SyncAll 执行完整主链路，返回汇总结果（即使部分失败也尽量返回汇总）。
//  1. tester.Run 测速（失败自动重测一次）
//  2. ExtractBestIPs 取最优 N
//  3. 将最优 IP 写入各 Provider 配置的 IP 源文件
//  4. 依次 CloudflareProvider.Sync / DNSPodProvider.Sync（DNSPod 按 isp_lines 各线路）
//  5. 把每次 Sync 的 SyncResult 写入 history.Append
//
// onProgress 为可选进度回调（变参，支持 0 或 1 个），用于向 CLI/GUI 上报阶段进度。
// 任一 Provider 同步失败均返回错误（对应原 sync.sh exit 1）。
func (s *Syncer) SyncAll(ctx context.Context, cfg *config.Config, onProgress ...ProgressFunc) (*SyncSummary, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}

	// 计算总阶段数（测速/提取/写入 + 启用的 Provider 同步）
	total := 3
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		total++
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		total++
	}
	cur := 0
	progress := func(phase string) {
		cur++
		for _, fn := range onProgress {
			if fn != nil {
				fn(phase, cur, total)
			}
		}
	}

	summary := &SyncSummary{}

	// ① 测速（失败自动重测一次）
	progress("speedtest")
	results, err := s.runSpeedtest(ctx, cfg)
	if err != nil {
		return summary, common.Wrap("sync:speedtest", err)
	}

	// ② 提取最优 N
	progress("extract")
	n := 5
	if cfg.CFIP != nil {
		n = cfg.CFIP.SpeedTest.TakeIPNum
	}
	if n <= 0 {
		n = 5
	}
	best := ExtractBestIPs(results, n)
	if len(best) == 0 {
		return summary, common.New("sync", "未提取到有效 IP")
	}
	summary.BestIPCount = len(best)
	common.Info("sync: 提取最优 IP", "count", len(best))

	// ③ 将最优 IP 写入各 Provider 配置的 IP 源文件，供 Sync 读取
	progress("write")
	if err := s.writeBestIPs(cfg, best); err != nil {
		return summary, common.Wrap("sync:write", err)
	}

	// ④ 依次同步 CF / DNSPod，并写入历史
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		progress("cloudflare")
		res, err := s.syncCloudflare(ctx, cfg)
		accumulate(summary, res)
		if err != nil {
			summary.Errors = append(summary.Errors, "cloudflare: "+err.Error())
			return summary, common.Wrap("sync:cf", err)
		}
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		progress("dnspod")
		res, err := s.syncDNSPod(ctx, cfg)
		accumulate(summary, res)
		if err != nil {
			summary.Errors = append(summary.Errors, "dnspod: "+err.Error())
			return summary, common.Wrap("sync:dnspod", err)
		}
	}

	return summary, nil
}

// accumulate 将单次 Sync 结果累加到汇总中（计数相加、错误合并）。
func accumulate(summary *SyncSummary, res *dns.SyncResult) {
	if summary == nil || res == nil {
		return
	}
	summary.Updated += res.Updated
	summary.Created += res.Created
	summary.Deleted += res.Deleted
	if len(res.Errors) > 0 {
		summary.Errors = append(summary.Errors, res.Errors...)
	}
}

// runSpeedtest 执行一次测速；若失败则自动重测一次（对应原 sync.sh auto_retry_test）。
func (s *Syncer) runSpeedtest(ctx context.Context, cfg *config.Config) ([]speedtest.SpeedResult, error) {
	results, err := s.tester.Run(ctx, cfg.CFIP)
	if err != nil {
		common.Warn("sync: 测速失败，尝试自动重测一次", "err", err.Error())
		results, err = s.tester.Run(ctx, cfg.CFIP)
		if err != nil {
			return nil, err
		}
	}
	return results, nil
}

// writeBestIPs 将最优 IP 列表写入 Cloudflare / DNSPod 配置的 IP 源文件。
func (s *Syncer) writeBestIPs(cfg *config.Config, best []ipsource.IPRecord) error {
	if cfg.CFDNS != nil && cfg.CFDNS.Enabled {
		if p := strings.TrimSpace(cfg.CFDNS.IPSource.FilePath); p != "" {
			if err := WriteIPList(best, p); err != nil {
				return common.Wrap("sync:write:cf", err)
			}
		}
	}
	if cfg.DNSPod != nil && cfg.DNSPod.Enabled {
		if strings.EqualFold(cfg.DNSPod.Mode, "isp_lines") {
			for _, conf := range cfg.DNSPod.ISP {
				if f := firstFile(conf); strings.TrimSpace(f) != "" {
					if err := WriteIPList(best, f); err != nil {
						return common.Wrap("sync:write:dnspod:"+f, err)
					}
				}
			}
		} else if p := strings.TrimSpace(cfg.DNSPod.IPFilePath); p != "" {
			if err := WriteIPList(best, p); err != nil {
				return common.Wrap("sync:write:dnspod", err)
			}
		}
	}
	return nil
}

// syncCloudflare 调用 CloudflareProvider.Sync 并写历史，返回同步结果。
func (s *Syncer) syncCloudflare(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	if cfg.CFDNS == nil || !cfg.CFDNS.Enabled {
		common.Info("sync: Cloudflare 模块未启用，跳过")
		return nil, nil
	}
	prov, ok := s.providers["cf"].(*dns.CloudflareProvider)
	if !ok {
		return nil, common.New("sync:cf", "未注册 CloudflareProvider")
	}
	res, err := prov.Sync(ctx, cfg.CFDNS)
	s.appendHistory("sync.cf", res, err)
	return res, err
}

// syncDNSPod 调用 DNSPodProvider.Sync 并写历史（按 isp_lines 各线路），返回同步结果。
func (s *Syncer) syncDNSPod(ctx context.Context, cfg *config.Config) (*dns.SyncResult, error) {
	if cfg.DNSPod == nil || !cfg.DNSPod.Enabled {
		common.Info("sync: DNSPod 模块未启用，跳过")
		return nil, nil
	}
	prov, ok := s.providers["dnspod"].(*dns.DNSPodProvider)
	if !ok {
		return nil, common.New("sync:dnspod", "未注册 DNSPodProvider")
	}
	res, err := prov.Sync(ctx, cfg.DNSPod)
	s.appendHistory("sync.dnspod", res, err)
	return res, err
}

// appendHistory 将一次 Sync 统计写入历史（成功/失败均记录）。
func (s *Syncer) appendHistory(action string, res *dns.SyncResult, syncErr error) {
	if s.history == nil {
		return
	}
	if res == nil {
		res = &dns.SyncResult{}
	}
	detail := fmt.Sprintf("updated=%d created=%d deleted=%d", res.Updated, res.Created, res.Deleted)
	if syncErr != nil {
		detail += " err=" + syncErr.Error()
	}
	if len(res.Errors) > 0 {
		detail += " sub=" + strings.Join(res.Errors, ";")
	}
	entry := history.HistoryEntry{Action: action, Detail: detail, Success: syncErr == nil}
	if err := s.history.Append(entry); err != nil {
		common.Warn("sync: 写入历史失败", "err", err.Error())
	}
}

// firstFile 取 ISPConf.IPSource.Files 中首个文件路径。
func firstFile(conf config.ISPConf) string {
	for _, v := range conf.IPSource.Files {
		return v
	}
	return ""
}
