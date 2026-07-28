package speedtest

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/ipsource"
)

// progressRe 匹配 cfst 进度日志中的 "X / Y" 形式。
// 注意：它也会误匹配 cfst 日志里的日期（如 2026/07/16 的 "2026/07" 片段），
// 扫描循环里通过相邻字符守卫（见 Run 中的进度解析）剔除这种误匹配。
var progressRe = regexp.MustCompile(`(\d+)\s*/\s*(\d+)`)

// DefaultSpeedtestTimeout cfst 单次测速默认超时（P1-4）。
// 可被外部 ctx 的更紧 deadline 收紧；外部无 deadline 时套用此 300s 上限。
const DefaultSpeedtestTimeout = 300 * time.Second

// cloudflareRangeURLs 是 Cloudflare 官方 IPv4/IPv6 地址段（CIDR）拉取地址。
// 声明为包级变量以便测试时临时替换为本地 httptest server。
var cloudflareRangeURLs = []string{
	"https://www.cloudflare.com/ips-v4",
	"https://www.cloudflare.com/ips-v6",
}

// CFSTTester 封装外部 cfst 二进制测速（对应已确认决策：保留 cfst sidecar，不写原生测速）。
type CFSTTester struct {
	binPath string
}

// NewCFSTTester 解析 cfst 二进制路径（多路径轮询，命中即停）：
//  1. resolveCFSTBinary(cfg) 原生结果（四级探测内已覆盖 CFSTPath / CFST.Binary / cwd / assets/cfst）
//  2. exeDir + resolveCFSTBinary 结果（适配 exe 邻近部署）
//  3. exeDir/assets/cfst/cfst[.exe]（适配 autoFetchCFST 下载到 exeDir/assets/cfst 的场景）
//  4. ./assets/cfst/cfst[.exe]（适配 CWD 部署）
//
// 解析失败返回含友好安装引导的错误（提示 `cfopt cfst fetch` 与官方 release 页面）。
func NewCFSTTester(cfg *config.CFIPConfig) (*CFSTTester, error) {
	if cfg == nil {
		return nil, common.New("speedtest:cfst", "配置为空")
	}

	exeDir := ""
	if exe, err := os.Executable(); err == nil {
		exeDir = filepath.Dir(exe)
	}

	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}

	// 收集所有候选路径
	rel := resolveCFSTBinary(cfg)
	candidates := []string{rel}
	if exeDir != "" {
		candidates = append(candidates,
			filepath.Join(exeDir, rel),                       // exeDir + relative result
			filepath.Join(exeDir, "assets", "cfst", binName), // explicit fallback
		)
	}
	candidates = append(candidates,
		filepath.Join(".", "assets", "cfst", binName), // CWD fallback
	)

	for _, p := range candidates {
		if p == "" {
			continue
		}
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			common.Debug("speedtest:cfst:resolve", "found cfst", "bin", p)
			return &CFSTTester{binPath: p}, nil
		}
	}

	return nil, common.Wrap("speedtest:cfst:resolve", fmt.Errorf(
		"cfst 二进制不存在: %s\n提示：可运行 `cfopt cfst fetch` 自动下载，或从 "+
			"https://github.com/XIU2/CloudflareSpeedTest/releases 手动获取后放到该路径", rel))
}

// resolveCFSTBinary 四级探测 cfst 二进制路径（命中即停），并用 common.Debug 输出最终选用名。
// 顺序：CFSTPath > CFST.Binary(若非空) > cfst/cfst.exe > assets/cfst/cfst[.exe]（与 cfst fetch 安装名一致）。
func resolveCFSTBinary(cfg *config.CFIPConfig) string {
	// 1) 显式覆盖 CFSTPath（最高优先）。
	if p := strings.TrimSpace(cfg.CFSTPath); p != "" {
		common.Debug("speedtest:cfst:resolve", "use CFSTPath", "bin", p)
		return p
	}
	// 2) CFST.Binary（若非空）。
	if p := strings.TrimSpace(cfg.CFST.Binary); p != "" {
		common.Debug("speedtest:cfst:resolve", "use CFST.Binary", "bin", p)
		return p
	}
	// 3) 工作目录下 cfst / cfst.exe（兼容手动放置或 PATH 同目录）。
	base := "cfst"
	if runtime.GOOS == "windows" {
		base = "cfst.exe"
	}
	if _, err := os.Stat(base); err == nil {
		common.Debug("speedtest:cfst:resolve", "use local", "bin", base)
		return base
	}
	// 4) assets/cfst/cfst[.exe]（默认探测，与 cfst fetch 安装名一致）。
	dir := cfg.CFST.Directory
	if dir == "" {
		dir = "assets/cfst"
	}
	binName := "cfst"
	if runtime.GOOS == "windows" {
		binName = "cfst.exe"
	}
	bin := filepath.Join(dir, binName)
	common.Debug("speedtest:cfst:resolve", "use default probe", "bin", bin)
	return bin
}

// buildCmd 构造 cfst 命令参数（cfst v2.3.5 / XIU2 版 flag 语义）。
// 注意：IP 文件（-f）不在本函数内拼装，而是交由 Run 通过 resolveIPFile 解析后追加，
// 以统一处理「配置指定 / 默认缓存 / 从 Cloudflare 官方拉取」三种来源。
//
// 关键映射（P1-6 修正）：
//
//	Threads    → -n  （线程数）
//	PingTimes  → -t  （延迟测速次数）
//	DownloadCount → -dn
//	DownloadTime  → -dt
//	Port      → -tp
//	URL       → -url
//	Colo      → -httping -cfcolo
//	LatencyMax → -tl
//	PacketLossMax → -tlr
//	SpeedMin  → -sl
//	ShowCount → -p
//	AllIP     → -allip
//	DisableDownload → -dd
//
// 各参数做下限保护（如 Threads>=1、PingTimes>=1），避免传 0/负值给 cfst。
func (t *CFSTTester) buildCmd(cfg *config.CFIPConfig, output string) []string {
	args := []string{"-o", output}
	cf := cfg.CFST

	// Threads → -n（线程数）
	if cf.Threads >= 1 {
		args = append(args, "-n", fmt.Sprintf("%d", cf.Threads))
	}
	// PingTimes → -t（延迟测速次数）
	if cf.PingTimes >= 1 {
		args = append(args, "-t", fmt.Sprintf("%d", cf.PingTimes))
	}
	// Port → -tp
	if cf.Port > 0 {
		args = append(args, "-tp", fmt.Sprintf("%d", cf.Port))
	}
	// DownloadCount → -dn
	if cf.DownloadCount > 0 {
		args = append(args, "-dn", fmt.Sprintf("%d", cf.DownloadCount))
	}
	// DownloadTime → -dt
	if cf.DownloadTime > 0 {
		args = append(args, "-dt", fmt.Sprintf("%d", cf.DownloadTime))
	}
	// URL → -url
	if url := strings.TrimSpace(cf.URL); url != "" {
		args = append(args, "-url", url)
	}
	// Colo → -httping -cfcolo（cfst v2.3.5 仅在 HTTPing 模式生效地区过滤）
	if colo := strings.TrimSpace(cf.Colo); colo != "" {
		args = append(args, "-httping", "-cfcolo", colo)
	}
	// LatencyMax → -tl
	if cf.LatencyMax > 0 {
		args = append(args, "-tl", strconv.FormatFloat(cf.LatencyMax, 'f', -1, 64))
	}
	// PacketLossMax → -tlr
	if cf.PacketLossMax > 0 {
		args = append(args, "-tlr", strconv.FormatFloat(cf.PacketLossMax, 'f', -1, 64))
	}
	// SpeedMin → -sl
	if cf.SpeedMin > 0 {
		args = append(args, "-sl", strconv.FormatFloat(cf.SpeedMin, 'f', -1, 64))
	}
	// ShowCount → -p
	if cf.ShowCount > 0 {
		args = append(args, "-p", fmt.Sprintf("%d", cf.ShowCount))
	}
	// AllIP → -allip
	if cf.AllIP {
		args = append(args, "-allip")
	}
	// DisableDownload → -dd
	if cf.DisableDownload {
		args = append(args, "-dd")
	}
	return args
}

// resolveIPFile 决定传给 cfst -f 的 IP 数据文件：
//  1. 配置了 cfst.ip_file 则直接用（不存在报错）；
//  2. 否则在 outputDir 下准备默认 ip.txt：已存在即用，不存在则从 Cloudflare 官方地址拉取并缓存。
func (t *CFSTTester) resolveIPFile(ctx context.Context, cfg *config.CFIPConfig, outputDir string) (string, error) {
	if ip := strings.TrimSpace(cfg.CFST.IPFile); ip != "" {
		if _, err := os.Stat(ip); err != nil {
			return "", common.Wrap("speedtest:cfst:ipfile", fmt.Errorf("配置的 cfst.ip_file 不存在: %s", ip))
		}
		return ip, nil
	}
	defaultPath := filepath.Join(outputDir, "ip.txt")
	if _, err := os.Stat(defaultPath); err == nil {
		return defaultPath, nil
	}
	if err := fetchCloudflareRanges(ctx, defaultPath); err != nil {
		return "", common.Wrap("speedtest:cfst:ipfile", err)
	}
	return defaultPath, nil
}

// fetchCloudflareRanges 从 Cloudflare 官方地址拉取 IPv4+IPv6 段并合并写入 dest。
// URL 来自包级变量 cloudflareRangeURLs（便于测试替换为本地 server）。
func fetchCloudflareRanges(ctx context.Context, dest string) error {
	var sb strings.Builder
	client := &http.Client{Timeout: 30 * time.Second}
	for _, u := range cloudflareRangeURLs {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return common.Wrap("speedtest:cfst:fetch", err)
		}
		resp, err := client.Do(req)
		if err != nil {
			return common.Wrap("speedtest:cfst:fetch "+u, err)
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return common.Wrap("speedtest:cfst:fetch "+u, fmt.Errorf("HTTP %d", resp.StatusCode))
		}
		if _, err := io.Copy(&sb, resp.Body); err != nil {
			resp.Body.Close()
			return common.Wrap("speedtest:cfst:fetch "+u, err)
		}
		resp.Body.Close()
		if !strings.HasSuffix(sb.String(), "\n") {
			sb.WriteString("\n")
		}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return common.Wrap("speedtest:cfst:fetch:mkdir", err)
	}
	if err := os.WriteFile(dest, []byte(sb.String()), 0o644); err != nil {
		return common.Wrap("speedtest:cfst:fetch:write", err)
	}
	return nil
}

// Run 执行 cfst 测速，期间另起 goroutine 解析 \r 进度日志，最终返回解析结果。
func (t *CFSTTester) Run(ctx context.Context, cfg *config.CFIPConfig) ([]SpeedResult, error) {
	outputDir := cfg.Paths.OutputDir
	if outputDir == "" {
		outputDir = "assets/data/cf-ip"
	}
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return nil, common.Wrap("speedtest:cfst:mkdir", err)
	}
	output := filepath.Join(outputDir, fmt.Sprintf("result_%s.csv", time.Now().Format("20060102_150405")))

	// 先解析 IP 数据文件（配置指定 / 默认缓存 / 官方拉取），再交给 cfst -f。
	ipFile, err := t.resolveIPFile(ctx, cfg, outputDir)
	if err != nil {
		return nil, err
	}
	args := t.buildCmd(cfg, output)
	if ipFile != "" {
		args = append(args, "-f", ipFile)
	}

	// P1-4：套用默认超时 300s；若外部 ctx 已设置更紧 deadline，则尊重外部（不放大）。
	runCtx := ctx
	var cancel context.CancelFunc
	if dl, ok := ctx.Deadline(); ok {
		if time.Until(dl) > DefaultSpeedtestTimeout {
			runCtx, cancel = context.WithTimeout(ctx, DefaultSpeedtestTimeout)
		}
	} else {
		runCtx, cancel = context.WithTimeout(ctx, DefaultSpeedtestTimeout)
	}
	if cancel != nil {
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, t.binPath, args...)

	// 合并 stdout/stderr 到同一管道，统一解析 cfst 进度日志（cfst 用 \r 覆盖同一行）。
	pr, pw := io.Pipe()
	// errBuf 同时捕获 cfst 的全部输出（含 stderr 报错文本），便于 cfst 以非 0 退出码
	// 失败时回传其真实报错（否则 cmd.Wait 只会给出 "exit status N" 而丢失真实原因）。
	var errBuf bytes.Buffer
	mw := io.MultiWriter(pw, &errBuf)
	cmd.Stdout = mw
	cmd.Stderr = mw

	common.Info("speedtest: 启动 cfst 测速", "bin", t.binPath, "output", output)
	if err := cmd.Start(); err != nil {
		_ = pw.Close()
		return nil, common.Wrap("speedtest:cfst:start", err)
	}

	// 另起 goroutine 解析进度（cfst 用 \r 覆盖进度行）
	done := make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(pr)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			// 按 \r 切分（cfst 用 \r 覆盖进度行）
			for _, seg := range strings.Split(line, "\r") {
				seg = strings.TrimSpace(seg)
				loc := progressRe.FindStringIndex(seg)
				if loc == nil {
					continue
				}
				// 防御误匹配日期片段（如 2026/07/16 的 "2026/07"）：
				// 真实进度 "X / Y" 两端不会紧邻 '/'，而日期的年/月或月/日之间都会有 '/'.
				if loc[0] > 0 && seg[loc[0]-1] == '/' {
					continue
				}
				if loc[1] < len(seg) && seg[loc[1]] == '/' {
					continue
				}
				common.Info("speedtest: 进度", "progress", seg[loc[0]:loc[1]])
			}
		}
	}()

	if err := cmd.Wait(); err != nil {
		_ = pw.Close()
		<-done
		// 回传 cfst 真实输出，避免用户只看到 "exit status N" 而看不到根因。
		if msg := strings.TrimSpace(errBuf.String()); msg != "" {
			return nil, common.Wrap("speedtest:cfst:wait", fmt.Errorf("%w: %s", err, msg))
		}
		return nil, common.Wrap("speedtest:cfst:wait", err)
	}
	_ = pw.Close()
	<-done

	results, err := t.ParseOutput(output)
	if err != nil {
		return nil, err
	}
	common.Info("speedtest: 测速完成", "count", len(results), "output", output)
	return results, nil
}

// ParseOutput 读取 cfst 生成的 CSV 并解析为 []SpeedResult。
func (t *CFSTTester) ParseOutput(path string) ([]SpeedResult, error) {
	records, err := (&ipsource.CSVParser{}).Read(path)
	if err != nil {
		return nil, common.Wrap("speedtest:cfst:parse", err)
	}
	results := make([]SpeedResult, 0, len(records))
	for _, r := range records {
		results = append(results, SpeedResult{
			IP:      r.IP,
			Latency: r.Latency,
			Speed:   r.Speed,
			Colo:    convertColoToName(r.Colo),
		})
	}
	return results, nil
}

// ToIPList 将测速结果转换为 IPRecord 列表。
func (t *CFSTTester) ToIPList(results []SpeedResult) []ipsource.IPRecord {
	out := make([]ipsource.IPRecord, 0, len(results))
	for _, r := range results {
		out = append(out, ipsource.IPRecord{
			IP:      r.IP,
			Latency: r.Latency,
			Speed:   r.Speed,
			Colo:    r.Colo,
		})
	}
	return out
}

// 编译期接口实现断言。
var _ SpeedTester = (*CFSTTester)(nil)
