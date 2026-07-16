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

// NewCFSTTester 解析 cfst 二进制路径：
// 优先 cfg.CFSTPath，否则按 assets/cfst/<goos>-<goarch>[.exe] 探测。
func NewCFSTTester(cfg *config.CFIPConfig) (*CFSTTester, error) {
	if cfg == nil {
		return nil, common.New("speedtest:cfst", "配置为空")
	}
	bin := cfg.CFSTPath
	if bin == "" {
		dir := cfg.CFST.Directory
		if dir == "" {
			dir = "assets/cfst"
		}
		bin = filepath.Join(dir, fmt.Sprintf("cfst-%s-%s", runtime.GOOS, runtime.GOARCH))
		if runtime.GOOS == "windows" {
			bin += ".exe"
		}
	}
	if _, err := os.Stat(bin); err != nil {
		return nil, common.Wrap("speedtest:cfst:resolve", fmt.Errorf("cfst 二进制不存在: %s", bin))
	}
	return &CFSTTester{binPath: bin}, nil
}

// buildCmd 构造 cfst 命令参数（最简 cfst -o output.csv，按 threads/colo/port/dd 加参）。
// 注意：IP 文件（-c）不在本函数内拼装，而是交由 Run 通过 resolveIPFile 解析后追加，
// 以统一处理「配置指定 / 默认缓存 / 从 Cloudflare 官方拉取」三种来源。
func (t *CFSTTester) buildCmd(cfg *config.CFIPConfig, output string) []string {
	args := []string{"-o", output}
	if cfg.CFST.Threads > 0 {
		args = append(args, "-t", fmt.Sprintf("%d", cfg.CFST.Threads))
	}
	if colo := strings.TrimSpace(cfg.CFST.Colo); colo != "" {
		// cfst v2.3.5 的地区过滤 flag 是 -cfcolo，且只在 HTTPing 模式下生效；
		// 因此配了 colo 时一并开启 -httping，否则 -cfcolo 会被忽略。
		args = append(args, "-httping", "-cfcolo", colo)
	}
	if cfg.CFST.Port > 0 {
		args = append(args, "-tp", fmt.Sprintf("%d", cfg.CFST.Port))
	}
	if cfg.CFST.DisableDownload {
		args = append(args, "-dd")
	}
	return args
}

// resolveIPFile 决定传给 cfst -c 的 IP 数据文件：
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

	// 先解析 IP 数据文件（配置指定 / 默认缓存 / 官方拉取），再交给 cfst -c。
	ipFile, err := t.resolveIPFile(ctx, cfg, outputDir)
	if err != nil {
		return nil, err
	}
	args := t.buildCmd(cfg, output)
	if ipFile != "" {
		args = append(args, "-c", ipFile)
	}
	cmd := exec.CommandContext(ctx, t.binPath, args...)

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
