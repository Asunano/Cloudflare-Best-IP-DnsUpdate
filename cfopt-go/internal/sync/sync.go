package sync

import (
	"context"
	"fmt"
	"path/filepath"
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
//
// 若某模块实现了可选的 dns.PerLineSpeedtester 且 UsePerLineSpeedtest 为真，
// 则对该模块执行「逐线路独立测速」（各线路用各自 CFSTConfig 测速并写各自 IP 文件），
// 并跳过全局 writeBestIPs（否则全局 best 会覆盖 per-line 各自文件，复活 P0-2）。
type Syncer struct {
	tester               speedtest.SpeedTester
	registry             *dns.Registry
	history              history.HistoryStore
	perLineTesterFactory func(*config.CFIPConfig) (speedtest.SpeedTester, error)
}

// NewSyncer 构造 Syncer。registry 通常由 BuildSyncerFromConfig 内部用 dns.BuiltinModules 构建。
// perLineTesterFactory 默认用 speedtest.NewCFSTTester（可在测试中注入 fake 以便验证逐线路分流）。
func NewSyncer(tester speedtest.SpeedTester, registry *dns.Registry, hist history.HistoryStore) *Syncer {
	return &Syncer{
		tester:  tester,
		registry: registry,
		history:  hist,
		perLineTesterFactory: func(c *config.CFIPConfig) (speedtest.SpeedTester, error) {
			return speedtest.NewCFSTTester(c)
		},
	}
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
	// 注入 history 给 cf 模块（覆盖 BuiltinModules 中的零值 cfModule，启用 P2-3 漂移/过期保护）。
	reg.Register(dns.NewCFModule(hist))
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
//  1. 全局模块：tester.Run 测速（失败自动重测一次）→ ExtractBestIPs → 写各自 IP 文件
//  2. 逐线路模块（dns.PerLineSpeedtester 且启用）：各线路独立测速 → 写各自 IP 文件（跳过全局 best）
//  3. 依次遍历选中模块并 Sync（各模块按 ID 作为 phase 推送进度、以 sync.<id> 写历史）
//  4. 把每次 Sync 的 SyncResult 累加进 summary
//
// onProgress 为可选进度回调（单参，可传 nil）。
// providers 为可选过滤：为空→全部启用模块；非空→仅指定且 Enabled 的 ID（向后兼容）。
func (s *Syncer) SyncAll(ctx context.Context, cfg *config.Config, onProgress ProgressFunc, providers ...string) (*SyncSummary, error) {
	if cfg == nil {
		return nil, common.New("sync", "配置为空")
	}

	// 确定本次要同步的模块（注册顺序；Enabled 且命中 providers 过滤）。
	selected := s.selectModules(cfg, providers)

	// 分区：逐线路模块 vs 全局模块（实现 dns.PerLineSpeedtester 且启用逐线路测速者归为前者）。
	var globalMods, perLineMods []dns.SyncModule
	for _, m := range selected {
		if pl, ok := m.(dns.PerLineSpeedtester); ok && pl.UsePerLineSpeedtest(cfg) {
			perLineMods = append(perLineMods, m)
		} else {
			globalMods = append(globalMods, m)
		}
	}

	// 预计算阶段序列，保证进度总数准确（全局 3 阶段 + 逐线路每线路 1 阶段 + 每模块 1 阶段）。
	var phases []string
	if len(globalMods) > 0 {
		phases = append(phases, "speedtest", "extract", "write")
	}
	for _, m := range perLineMods {
		pl := m.(dns.PerLineSpeedtester)
		for _, job := range pl.SpeedtestJobs(cfg) {
			phases = append(phases, "speedtest:"+job.Line)
		}
	}
	for _, m := range selected {
		phases = append(phases, m.ID())
	}
	total := len(phases)
	cur := 0
	progress := func(phase string) {
		cur++
		if onProgress != nil {
			onProgress(phase, cur, total)
		}
	}

	summary := &SyncSummary{}

	// ① 全局模块：单次测速 → 提取最优 N → 写入各全局模块 IP 源文件。
	if len(globalMods) > 0 {
		progress("speedtest")
		results, err := s.runSpeedtest(ctx, cfg)
		if err != nil {
			return summary, common.Wrap("sync:speedtest", err)
		}

		progress("extract")
		best := ExtractBestIPs(results, takeIPNum(cfg))
		if len(best) == 0 {
			return summary, common.New("sync", "未提取到有效 IP")
		}
		summary.BestIPCount = len(best)
		common.Info("sync: 提取最优 IP", "count", len(best))

		progress("write")
		if err := s.writeBestIPs(cfg, best, globalMods); err != nil {
			return summary, common.Wrap("sync:write", err)
		}
		// 全局最优 IP 强制落盘为 .iplist（供统一子域 global_best 模式读取首行 IP）。
		// 仅当存在全局模块时写入；per-line 全占时跳过，避免空文件误导 global_best 降级。
		if gp := globalBestPath(cfg); gp != "" {
			if err := WriteIPList(best, gp); err != nil {
				return summary, common.Wrap("sync:write:globalbest", err)
			}
			common.Info("sync: 全局最优 IP 已落盘", "path", gp, "count", len(best))
		}
	} else if len(perLineMods) > 0 {
		common.Info("sync: 全部为逐线路模块，跳过全局测速与 writeBestIPs（避免覆盖 per-line 各自文件）")
	}

	// ② 逐线路模块：各线路独立测速 → 提取 → 写入各自 IP 文件（绝不走全局 best）。
	for _, m := range perLineMods {
		pl := m.(dns.PerLineSpeedtester)
		for _, job := range pl.SpeedtestJobs(cfg) {
			progress("speedtest:" + job.Line)
			cfip := buildPerLineCFIP(cfg.CFIP, job.CFST)
			// 输出到独立子目录，避免与全局/其他线路共用 CSV 与缓存 ip.txt 产生碰撞。
			if cfg.CFIP != nil && cfg.CFIP.Paths.OutputDir != "" {
				cfip.Paths.OutputDir = filepath.Join(cfg.CFIP.Paths.OutputDir, "perline", sanitizeLine(job.Line))
			}
			tester, err := s.perLineTesterFactory(cfip)
			if err != nil {
				return summary, common.Wrap("sync:perline:tester:"+job.Line, err)
			}
			results, err := tester.Run(ctx, cfip)
			if err != nil {
				summary.Errors = append(summary.Errors, "perline:"+job.Line+": "+err.Error())
				return summary, common.Wrap("sync:perline:"+job.Line, err)
			}
			best := ExtractBestIPs(results, takeIPNum(cfg))
			if len(best) == 0 {
				summary.Errors = append(summary.Errors, "perline:"+job.Line+": 未提取到有效 IP")
				return summary, common.New("sync:perline:"+job.Line, "未提取到有效 IP")
			}
			common.Info("sync: 逐线路测速完成", "line", job.Line, "count", len(best))
			if err := s.writeIPListToFiles(best, job.IPFiles); err != nil {
				return summary, common.Wrap("sync:perline:write:"+job.Line, err)
			}
		}
	}

	// ③ 依次同步选中模块（per-line 与 global 一并），并写入历史。
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

// takeIPNum 返回提取最优 IP 数量（默认 5）。
func takeIPNum(cfg *config.Config) int {
	n := 5
	if cfg != nil && cfg.CFIP != nil {
		n = cfg.CFIP.SpeedTest.TakeIPNum
	}
	if n <= 0 {
		n = 5
	}
	return n
}

// globalBestPath 返回全局最优 IP 文件路径：优先 cfg.CFIP.Paths.GlobalBestFile，空则 DefaultGlobalBestIPFile。
func globalBestPath(cfg *config.Config) string {
	if cfg != nil && cfg.CFIP != nil && cfg.CFIP.Paths.GlobalBestFile != "" {
		return cfg.CFIP.Paths.GlobalBestFile
	}
	return config.DefaultGlobalBestIPFile
}

// buildPerLineCFIP 合并全局 CFIP 与单线路测速参数（LineSpeedtestJob.CFST，*config.CFSTConfig），
// 返回用于构造该线路 CFSTTester 的配置。仅覆盖有值的字段；其余沿用全局。
//
// 设计说明：LineSpeedtestJob.CFST 为 *config.CFSTConfig（由 dnspodModule.SpeedtestJobs 依据
// ISPConf.SpeedTest 构造），故此处入参为 *config.CFSTConfig（与 ISPSpeedTestConfig 字段对应，
// 但已是展开后的 CFST 子集），以字段级合并避免覆盖全局其它测速参数。
// 注意：输出子目录（避免 CSV/ip.txt 碰撞）由调用方依据线路名另行设置。
func buildPerLineCFIP(global *config.CFIPConfig, lineCfg *config.CFSTConfig) *config.CFIPConfig {
	if global == nil {
		return &config.CFIPConfig{}
	}
	out := *global
	cfst := global.CFST
	if lineCfg != nil {
		if lineCfg.Colo != "" {
			cfst.Colo = lineCfg.Colo
		}
		if lineCfg.Threads >= 1 {
			cfst.Threads = lineCfg.Threads
		}
		if lineCfg.DisableDownload {
			cfst.DisableDownload = true
		}
		if lineCfg.IPFile != "" {
			cfst.IPFile = lineCfg.IPFile
		}
		if lineCfg.Port > 0 {
			cfst.Port = lineCfg.Port
		}
		if lineCfg.URL != "" {
			cfst.URL = lineCfg.URL
		}
		if lineCfg.DownloadCount > 0 {
			cfst.DownloadCount = lineCfg.DownloadCount
		}
		if lineCfg.DownloadTime > 0 {
			cfst.DownloadTime = lineCfg.DownloadTime
		}
		if lineCfg.LatencyMax > 0 {
			cfst.LatencyMax = lineCfg.LatencyMax
		}
		if lineCfg.PacketLossMax > 0 {
			cfst.PacketLossMax = lineCfg.PacketLossMax
		}
		if lineCfg.SpeedMin > 0 {
			cfst.SpeedMin = lineCfg.SpeedMin
		}
		if lineCfg.ShowCount > 0 {
			cfst.ShowCount = lineCfg.ShowCount
		}
		if lineCfg.AllIP {
			cfst.AllIP = true
		}
	}
	out.CFST = cfst
	return &out
}

// sanitizeLine 将线路名转为安全的目录名片段（替换路径分隔符与空格）。
func sanitizeLine(line string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_", " ", "_")
	return replacer.Replace(line)
}

// writeIPListToFiles 将最优 IP 列表写入指定 IP 文件集合（用于逐线路模块）。
func (s *Syncer) writeIPListToFiles(best []ipsource.IPRecord, files []string) error {
	for _, f := range files {
		if strings.TrimSpace(f) == "" {
			continue
		}
		if err := WriteIPList(best, f); err != nil {
			return common.Wrap("sync:write:file:"+f, err)
		}
	}
	return nil
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
