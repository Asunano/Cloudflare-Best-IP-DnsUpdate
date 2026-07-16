package ipc

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"path/filepath"
	"strings"
	"sync/atomic"

	"cfopt/internal/common"
	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/speedtest"
	"cfopt/internal/sync"
)

// Services 聚合 GUI 所需后端能力。cmd/serve.go 用真实的 internal 类型注入具体实现。
// 注意：本包仅依赖 internal/*，严禁 import cmd，避免产生 import cycle。
type Services struct {
	Config    ConfigService
	Sync      SyncService
	Speedtest SpeedtestService
	History   HistoryService
	Daemon    DaemonService
	Version   VersionService
}

// ConfigService 配置读写能力。
type ConfigService interface {
	Get() (*config.Config, error)
	Validate(cfg *config.Config) error
	Save(cfg *config.Config) error
}

// SyncService 一键同步能力。Run 的 onProgress 直接复用 sync.ProgressFunc（签名一致）。
// providers 为可选过滤：为空→全部启用模块；非空→仅指定且 Enabled 的 ID（向后兼容）。
type SyncService interface {
	Run(ctx context.Context, onProgress sync.ProgressFunc, providers ...string) (*sync.SyncSummary, error)
}

// SpeedtestService 测速能力。
type SpeedtestService interface {
	Run(ctx context.Context) ([]speedtest.SpeedResult, error)
}

// HistoryService 历史记录读取能力。
type HistoryService interface {
	List(n int) ([]history.HistoryEntry, error)
}

// DaemonService 系统服务（调度 daemon）控制能力。
type DaemonService interface {
	Install() error
	Uninstall() error
	Start() error
	Stop() error
	Status() (DaemonStatus, error)
}

// VersionService 版本信息能力。
type VersionService interface {
	Info() VersionInfo
}

// Server 监听 TCP loopback 并派发 JSON-RPC 请求。
type Server struct {
	svc      Services
	ln       net.Listener
	shutdown atomic.Bool
}

// NewServer 构造 IPC 服务（尚未开始监听）。
func NewServer(svc Services) *Server {
	return &Server{svc: svc}
}

// Listen 在 addr 上监听 TCP。addr 使用 "127.0.0.1:0" 时由系统分配随机端口。
// 返回实际监听端口，供调用方写入端口发现文件（如供 Rust sidecar 轮询）。
func (s *Server) Listen(addr string) (int, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return 0, err
	}
	s.ln = ln
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// Serve 接受循环：每来一个连接，起一个 goroutine 处理（ServeConn）。
// 优雅关闭时 Accept 返回 net.ErrClosed，此时直接正常返回 nil。
func (s *Server) Serve() error {
	if s.ln == nil {
		return errors.New("ipc: server not listening")
	}
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			if s.shutdown.Load() {
				return nil
			}
			return err
		}
		go s.ServeConn(conn)
	}
}

// Shutdown 优雅关闭：标记关闭并关闭 listener，使 Serve 的 Accept 立即返回。
func (s *Server) Shutdown(_ context.Context) error {
	s.shutdown.Store(true)
	if s.ln != nil {
		return s.ln.Close()
	}
	return nil
}

// ServeConn 处理单个连接：按行解码 JSON-RPC 请求，派发，回写响应；
// sync.run 会在最终响应之前穿插推送 progress 事件。
func (s *Server) ServeConn(conn net.Conn) {
	defer conn.Close()
	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)
	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			if errors.Is(err, io.EOF) {
				return
			}
			// 解析失败：回写 parse error 后关闭（单行损坏，不再继续解析）。
			_ = enc.Encode(Response{
				JSONRPC: ProtocolVersion,
				Error:   &RPCError{Code: CodeParseError, Message: err.Error()},
			})
			return
		}
		reqID := parseID(req.ID)
		result, err := s.dispatch(enc, req, reqID)
		resp := Response{JSONRPC: ProtocolVersion, ID: req.ID}
		if err != nil {
			resp.Error = toRPCError(err)
		} else {
			resp.Result = result
		}
		if err := enc.Encode(resp); err != nil {
			return
		}
	}
}

// dispatch 路由请求方法并返回结果（sync.run 会在返回前穿插推送 progress 事件）。
func (s *Server) dispatch(enc *json.Encoder, req Request, reqID int64) (interface{}, error) {
	ctx := context.Background()
	switch req.Method {
	case "ping":
		return map[string]interface{}{"pong": true}, nil
	case "version":
		return s.svc.Version.Info(), nil
	case "config.get":
		return s.svc.Config.Get()
	case "config.validate":
		// params 可选：提供则校验传入配置；缺省（nil/空）则校验当前已加载配置。
		if len(req.Params) > 0 {
			var cfg config.Config
			if err := json.Unmarshal(req.Params, &cfg); err != nil {
				return nil, &RPCError{Code: CodeInvalidParams, Message: err.Error()}
			}
			if err := s.svc.Config.Validate(&cfg); err != nil {
				return nil, err
			}
		} else {
			loaded, err := s.svc.Config.Get()
			if err != nil {
				return nil, err
			}
			if loaded == nil {
				return nil, &RPCError{Code: CodeInternalError, Message: "no config loaded"}
			}
			if err := s.svc.Config.Validate(loaded); err != nil {
				return nil, err
			}
		}
		return map[string]bool{"ok": true}, nil
	case "config.save":
		// params 必填：必须提供一个 Config 对象，缺省视为无效参数。
		if len(req.Params) == 0 {
			return nil, &RPCError{Code: CodeInvalidParams, Message: "config.save requires a config object"}
		}
		var cfg config.Config
		if err := json.Unmarshal(req.Params, &cfg); err != nil {
			return nil, &RPCError{Code: CodeInvalidParams, Message: err.Error()}
		}
		if err := s.svc.Config.Save(&cfg); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	case "sync.run":
		return s.handleSyncRun(ctx, enc, req, reqID)
	case "speedtest.run":
		return s.handleSpeedtestRun(ctx)
	case "history.list":
		// params 可选：提供 n 则使用；缺省（nil/空）沿用默认 n = 20。
		n := 20
		if len(req.Params) > 0 {
			var p struct {
				N int `json:"n"`
			}
			if err := json.Unmarshal(req.Params, &p); err != nil {
				return nil, &RPCError{Code: CodeInvalidParams, Message: err.Error()}
			}
			if p.N > 0 {
				n = p.N
			}
		}
		return s.svc.History.List(n)
	case "daemon.install":
		if err := s.svc.Daemon.Install(); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	case "daemon.uninstall":
		if err := s.svc.Daemon.Uninstall(); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	case "daemon.start":
		if err := s.svc.Daemon.Start(); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	case "daemon.stop":
		if err := s.svc.Daemon.Stop(); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	case "daemon.status":
		return s.svc.Daemon.Status()
	default:
		return nil, &RPCError{Code: CodeMethodNotFound, Message: "unknown method: " + req.Method}
	}
}

// handleSyncRun 执行同步；在最终响应之前，于同一连接上穿插推送 progress 事件。
// onProgress 闭包即 sync.ProgressFunc，直接复用 Sync 层的进度回调签名。
// 解析 params.providers（string 数组，可空）并透传给 SyncService.Run，实现按 provider 过滤。
func (s *Server) handleSyncRun(ctx context.Context, enc *json.Encoder, req Request, reqID int64) (interface{}, error) {
	var params struct {
		Providers []string `json:"providers"`
	}
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return nil, &RPCError{Code: CodeInvalidParams, Message: err.Error()}
		}
	}

	onProgress := func(phase string, cur, total int) {
		_ = enc.Encode(Event{
			JSONRPC: ProtocolVersion,
			Method:  "progress",
			Params: ProgressEvent{
				ReqID:   reqID,
				Phase:   phase,
				Cur:     cur,
				Total:   total,
				Message: phase,
			},
		})
	}
	return s.svc.Sync.Run(ctx, onProgress, params.Providers...)
}

// handleSpeedtestRun 执行测速；与 CLI `cfopt speedtest --output` 默认行为一致，
// 在返回结果的同时把最优 IP 补写一份 .iplist 文件（路径同 CLI 默认：<output_dir>/best_ips.iplist）。
// 写文件失败仅告警，不影响结果返回（IPC 首要契约是返回测速结果）。
func (s *Server) handleSpeedtestRun(ctx context.Context) (interface{}, error) {
	results, err := s.svc.Speedtest.Run(ctx)
	if err != nil {
		return nil, err
	}
	if wErr := s.writeSpeedtestIPList(ctx, results); wErr != nil {
		common.Warn("speedtest.run: 补写 .iplist 失败", "err", wErr.Error())
	}
	return results, nil
}

// writeSpeedtestIPList 将测速结果转换为 IPRecord 并写入默认 .iplist 文件。
// 无 cf-ip 配置（CLI 同样需要）或 OutputDir 为空时跳过，不视为错误。
func (s *Server) writeSpeedtestIPList(_ context.Context, results []speedtest.SpeedResult) error {
	cfg, err := s.svc.Config.Get()
	if err != nil {
		return common.Wrap("speedtest:cfg", err)
	}
	if cfg == nil || cfg.CFIP == nil {
		return nil
	}
	recs := speedtest.ToIPList(results)
	output := filepath.Join(cfg.CFIP.Paths.OutputDir, "best_ips.iplist")
	if err := sync.WriteIPList(recs, output); err != nil {
		return common.Wrap("speedtest:write", err)
	}
	return nil
}

// parseID 将原始 id 解析为 int64（解析失败保持 0）。
func parseID(raw json.RawMessage) int64 {
	var id int64
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &id)
	}
	return id
}

// toRPCError 将 error 转换为 *RPCError；若已是 *RPCError 则原样返回。
// 对常见错误做粗略码映射，其余归为 CodeInternalError。
func toRPCError(err error) *RPCError {
	if err == nil {
		return nil
	}
	if re, ok := err.(*RPCError); ok {
		return re
	}
	msg := err.Error()
	code := CodeInternalError
	switch {
	case strings.Contains(msg, "not found"), strings.Contains(msg, "unknown method"):
		code = CodeMethodNotFound
	case strings.Contains(msg, "invalid params"), strings.Contains(msg, "json"):
		code = CodeInvalidParams
	}
	return &RPCError{Code: code, Message: msg}
}
