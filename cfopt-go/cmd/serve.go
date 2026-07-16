package cmd

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/spf13/cobra"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/scheduler"
	"cfopt/internal/speedtest"
	"cfopt/internal/sync"
	"cfopt/pkg/ipc"
)

// newServeCmd 构造 `cfopt serve` 命令：启动 IPC 服务，供 Tauri/Rust sidecar 经 JSON-RPC 调用。
func newServeCmd() *cobra.Command {
	var ipcAddr, ipcPortFile string
	cmd := &cobra.Command{
		Use:   "serve",
		Short: "启动 IPC 服务（供 Tauri/Rust sidecar 经 JSON-RPC 调用）",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runServe(ipcAddr, ipcPortFile)
		},
	}
	cmd.Flags().StringVar(&ipcAddr, "ipc-addr", "127.0.0.1:0", "IPC 监听地址（默认随机端口 127.0.0.1:0）")
	cmd.Flags().StringVar(&ipcPortFile, "ipc-port-file", "", "将实际端口写入此文件（供 Rust sidecar 发现；tmp+rename 原子写）")
	return cmd
}

// runServe 监听并运行 IPC 服务，直至收到 SIGINT/SIGTERM 优雅退出。
// 直接使用 cmd 包全局变量 cfgDir（--config-dir 的当前值）。
func runServe(ipcAddr, ipcPortFile string) error {
	svc := buildServices(cfgDir)
	srv := ipc.NewServer(svc)
	port, err := srv.Listen(ipcAddr)
	if err != nil {
		return common.Wrap("serve:listen", err)
	}
	common.Info("serve: IPC 监听", "addr", fmt.Sprintf("127.0.0.1:%d", port))
	if ipcPortFile != "" {
		if err := writePortFile(ipcPortFile, port); err != nil {
			return common.Wrap("serve:portfile", err)
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		_ = srv.Shutdown(context.Background())
	}()

	if err := srv.Serve(); err != nil && !errors.Is(err, net.ErrClosed) {
		return common.Wrap("serve", err)
	}
	return nil
}

// buildServices 将真实 internal 实现注入 ipc.Services（GUI 后端接缝）。
func buildServices(cfgDir string) ipc.Services {
	return ipc.Services{
		Config:    &configService{cfgDir: cfgDir},
		Sync:      &syncService{cfgDir: cfgDir},
		Speedtest: &speedtestService{cfgDir: cfgDir},
		History:   &historyService{cfgDir: cfgDir},
		Daemon:    &daemonService{cfgDir: cfgDir},
		Version:   &versionService{},
	}
}

// ---------------------------------------------------------------------------
// ConfigService
// ---------------------------------------------------------------------------

type configService struct{ cfgDir string }

// Get 一律用 LoadFresh 读取最新磁盘值（config.Load 有 sync.Once 缓存，GUI 的 save→get 必须反映最新值）。
func (s *configService) Get() (*config.Config, error) { return config.LoadFresh(s.cfgDir) }

func (s *configService) Validate(cfg *config.Config) error { return config.Validate(cfg) }

func (s *configService) Save(cfg *config.Config) error { return config.Save(s.cfgDir, cfg) }

// ---------------------------------------------------------------------------
// SyncService
// ---------------------------------------------------------------------------

type syncService struct{ cfgDir string }

func (s *syncService) Run(ctx context.Context, onProgress sync.ProgressFunc) (*sync.SyncSummary, error) {
	cfg, err := config.LoadFresh(s.cfgDir)
	if err != nil {
		return nil, err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return nil, err
	}
	syncer, err := sync.BuildSyncerFromConfig(cfg, hist)
	if err != nil {
		return nil, err
	}
	return syncer.SyncAll(ctx, cfg, onProgress)
}

// ---------------------------------------------------------------------------
// SpeedtestService
// ---------------------------------------------------------------------------

type speedtestService struct{ cfgDir string }

func (s *speedtestService) Run(ctx context.Context) ([]speedtest.SpeedResult, error) {
	cfg, err := config.LoadFresh(s.cfgDir)
	if err != nil {
		return nil, err
	}
	if cfg.CFIP == nil {
		return nil, common.New("serve:speedtest", "缺少 cf-ip 配置")
	}
	tester, err := speedtest.NewCFSTTester(cfg.CFIP)
	if err != nil {
		return nil, err
	}
	return tester.Run(ctx, cfg.CFIP)
}

// ---------------------------------------------------------------------------
// HistoryService
// ---------------------------------------------------------------------------

type historyService struct{ cfgDir string }

func (s *historyService) List(n int) ([]history.HistoryEntry, error) {
	cfg, err := config.LoadFresh(s.cfgDir)
	if err != nil {
		return nil, err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return nil, err
	}
	return hist.ReadLatest(n)
}

// ---------------------------------------------------------------------------
// DaemonService
// ---------------------------------------------------------------------------

type daemonService struct{ cfgDir string }

// build 构建 Daemon（每次调用均 LoadFresh + 重建，保证反映最新配置）。
func (s *daemonService) build() (*scheduler.Daemon, error) {
	cfg, err := config.LoadFresh(s.cfgDir)
	if err != nil {
		return nil, err
	}
	hist, err := newHistoryStore(cfg)
	if err != nil {
		return nil, err
	}
	sched, err := scheduler.NewScheduler(cfg, hist)
	if err != nil {
		return nil, err
	}
	return scheduler.NewDaemon(sched, cfg, parseInterval(cfg), false), nil
}

func (s *daemonService) Install() error {
	d, err := s.build()
	if err != nil {
		return err
	}
	return d.RunService("install")
}

func (s *daemonService) Uninstall() error {
	d, err := s.build()
	if err != nil {
		return err
	}
	return d.RunService("uninstall")
}

func (s *daemonService) Start() error {
	d, err := s.build()
	if err != nil {
		return err
	}
	return d.RunService("start")
}

func (s *daemonService) Stop() error {
	d, err := s.build()
	if err != nil {
		return err
	}
	return d.RunService("stop")
}

func (s *daemonService) Status() (ipc.DaemonStatus, error) {
	d, err := s.build()
	if err != nil {
		return ipc.DaemonStatus{State: "unknown"}, err
	}
	st, err := d.Status()
	if err != nil {
		return ipc.DaemonStatus{State: "unknown"}, err
	}
	return ipc.DaemonStatus{State: st}, nil
}

// ---------------------------------------------------------------------------
// VersionService
// ---------------------------------------------------------------------------

type versionService struct{}

func (s *versionService) Info() ipc.VersionInfo {
	return ipc.VersionInfo{Version: Version, Commit: Commit, BuiltAt: BuiltAt}
}

// writePortFile 将端口原子写入文件（tmp + rename），供 Rust sidecar 轮询发现。
func writePortFile(path string, port int) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(port)+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
