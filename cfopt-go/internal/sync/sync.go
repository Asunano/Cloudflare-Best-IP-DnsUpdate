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

// Syncer 编排「测速 → 提取最优 IP → 写入各模块 IP 源文件 → 遍历 Registry 同步 → 写历史」主链路。
//
// 中心只依赖 dns.SyncModule 接口与 dns.Registry，完全不感知具体 DNS 商；
// 新增 provider 只需实现 SyncModule 并注册进 Registry，本文件逻辑零改动。
type Syncer struct {
	tester   speedtest.SpeedTester
	registry *dns.Registry
	history  history.HistoryStore
}

// NewSyncer 构造 Syncer。registry 通常由 BuildSyncerFromConfig 内部用 dns.BuiltinModules 构建。
func NewSyncer(tester speedtest.SpeedTester, registry *dns.Registry, hist history.HistoryStore) *Syncer {
	return &Syncer{tester: tester, registry: registry, history: hist}
}

// BuildSyncerFromConfig 从配置构造 Syncer（自动构建 CFSTTester 并以 BuiltinModules 注册 Registry）。
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
	reg := dns.NewRegistry()
	reg.RegisterAll(dns.BuiltinModules)
	return NewSyncer(tester, reg, hist), nil
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

// selectModules 确定本次要同步的模块：按注册顺序，要求 Enabled(cfg) 且（providers 为空 或 ID 命中 providers）。
func (s *Syncer) selectModules(cfg *config.Config, providers []string) []dns.SyncModule {
	filter := make(map[string]bool, len(providers))
	for _, p := range providers {
		if p = strings.TrimSpace(p); p != "" {
			filter[p] = true
		}
	}
	onlyFilter := len(filter) > 0

	out := make([]dns.SyncModule, 0, len(s.registry.Modules()))
	for _, m := range s.registry.Modules() {
		if !m.Enabled(cfg) {
			continue
		}
		if onlyFilter && !filter[m.ID()] {
			continue
		}
		out = append(out, m)
	}
	return out
}

// SyncAll 执行完整主链路，返回汇总结果（即使部分失败也尽量返回汇总）。
//  1. tester.Run 测速（失败自动重测一次）
//  2. ExtractBestIPs 取最优 N
//  3. 将最优 IP 写入各选中模块的 IP 源文件
//  4. 依次遍历选中模块并 Sync（各模块按 ID 作为 phase 推送进度、以 sync.<id> 写历史）
//  5. 把每次 Sync 的 SyncResult 累加进 summary
//
// onProgress 为可选进度回调（单参，可传 nil）。
// providers 为可选过滤：为空→全部启用模块；非空→仅指定且 Enabled 的 ID（向后兼容）。
func (s *Syncer) SyncAll(ctx context.Context, cfg *config.Config, onProgress ProgressFunc, providers ...string) (*SyncSummary, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}

	// 确定本次要同步的模块（注册顺序；Enabled 且命中 providers 过滤）。
	selected := s.selectModules(cfg, providers)

	// 总阶段数 = 测速/提取/写入 + 启用且命中的模块数。
	total := 3 + len(selected)
	cur := 0
	progress := func(phase string) {
		cur++
		if onProgress != nil {
			onProgress(phase, cur, total)
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

	// ③ 将最优 IP 写入各选中模块的 IP 源文件，供 Sync 读取
	progress("write")
	if err := s.writeBestIPs(cfg, best, selected); err != nil {
		return summary, common.Wrap("sync:write", err)
	}

	// ④ 依次同步选中模块，并写入历史
	for _, m := range selected {
		progress(m.ID())
		res, err := m.Sync(ctx, cfg)
		accumulate(summary, res)
		s.appendHistory("sync."+m.ID(), res, err)
		if err != nil {
			summary.Errors = append(summary.Errors, m.ID()+": "+err.Error())
			return summary, common.Wrap("sync:"+m.ID(), err)
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

// writeBestIPs 将最优 IP 列表写入各选中模块的 IP 源文件（模块未声明文件或路径为空则跳过）。
func (s *Syncer) writeBestIPs(cfg *config.Config, best []ipsource.IPRecord, modules []dns.SyncModule) error {
	for _, m := range modules {
		for _, f := range m.IPSourceFiles(cfg) {
			if strings.TrimSpace(f) == "" {
				continue
			}
			if err := WriteIPList(best, f); err != nil {
				return common.Wrap("sync:write:"+m.ID()+":"+f, err)
			}
		}
	}
	return nil
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
