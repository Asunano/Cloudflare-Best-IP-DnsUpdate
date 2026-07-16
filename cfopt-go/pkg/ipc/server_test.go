package ipc

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"testing"

	"cfopt/internal/config"
	"cfopt/internal/history"
	"cfopt/internal/speedtest"
	"cfopt/internal/sync"
)

// ---------------------------------------------------------------------------
// fakes：内存态实现 6 个 Services 接口，不依赖真实网络 / API。
// ---------------------------------------------------------------------------

type fakeConfigService struct{}

func (f *fakeConfigService) Get() (*config.Config, error) {
	return &config.Config{Global: &config.GlobalConfig{}}, nil
}
func (f *fakeConfigService) Validate(cfg *config.Config) error { return nil }
func (f *fakeConfigService) Save(cfg *config.Config) error     { return nil }

type fakeSyncService struct{}

func (f *fakeSyncService) Run(ctx context.Context, onProgress sync.ProgressFunc) (*sync.SyncSummary, error) {
	onProgress("speedtest", 1, 3)
	onProgress("extract", 2, 3)
	onProgress("write", 3, 3)
	return &sync.SyncSummary{BestIPCount: 3, Updated: 1}, nil
}

type fakeSpeedtestService struct{}

func (f *fakeSpeedtestService) Run(ctx context.Context) ([]speedtest.SpeedResult, error) {
	return []speedtest.SpeedResult{}, nil
}

type fakeHistoryService struct{}

func (f *fakeHistoryService) List(n int) ([]history.HistoryEntry, error) {
	return []history.HistoryEntry{
		{Action: "sync.cf"},
		{Action: "sync.dnspod"},
	}, nil
}

type fakeDaemonService struct{}

func (f *fakeDaemonService) Install() error                          { return nil }
func (f *fakeDaemonService) Uninstall() error                        { return nil }
func (f *fakeDaemonService) Start() error                            { return nil }
func (f *fakeDaemonService) Stop() error                             { return nil }
func (f *fakeDaemonService) Status() (DaemonStatus, error) {
	return DaemonStatus{State: "running"}, nil
}

type fakeVersionService struct{}

func (f *fakeVersionService) Info() VersionInfo {
	return VersionInfo{Version: "test", Commit: "abc", BuiltAt: "2024"}
}

func newFakeServices() Services {
	return Services{
		Config:    &fakeConfigService{},
		Sync:      &fakeSyncService{},
		Speedtest: &fakeSpeedtestService{},
		History:   &fakeHistoryService{},
		Daemon:    &fakeDaemonService{},
		Version:   &fakeVersionService{},
	}
}

// ---------------------------------------------------------------------------
// 测试工具
// ---------------------------------------------------------------------------

// rpcEnvelope 是客户端读取的联合结构（响应 / 事件 / 通知共用同一帧格式）。
type rpcEnvelope struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// startTestServer 起一个监听 127.0.0.1:0 的服务，返回端口、Server 与停止函数。
func startTestServer(t *testing.T) (int, *Server, func()) {
	t.Helper()
	srv := NewServer(newFakeServices())
	port, err := srv.Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = srv.Serve() }()
	return port, srv, func() { _ = srv.Shutdown(context.Background()) }
}

// dialTest 连接到测试服务并写入一条请求，返回编码器/解码器。
func dialTest(t *testing.T, port int) (*json.Encoder, *json.Decoder) {
	t.Helper()
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return json.NewEncoder(conn), json.NewDecoder(conn)
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

func TestPing(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("1"), Method: "ping"}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error != nil {
		t.Fatalf("unexpected error: %+v", env.Error)
	}
	var res map[string]interface{}
	if err := json.Unmarshal(env.Result, &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if res["pong"] != true {
		t.Fatalf("expected pong==true, got %v", res["pong"])
	}
}

func TestConfigGet(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("2"), Method: "config.get"}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error != nil {
		t.Fatalf("unexpected error: %+v", env.Error)
	}
	if env.Result == nil {
		t.Fatalf("config.get result should be non-nil")
	}
	// *config.Config 应为一个 JSON 对象（非 null）。
	var cfg map[string]interface{}
	if err := json.Unmarshal(env.Result, &cfg); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}
	if cfg == nil {
		t.Fatalf("expected non-nil config object")
	}
}

func TestSyncRunProgress(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	reqID := json.RawMessage("7")
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: reqID, Method: "sync.run"}); err != nil {
		t.Fatalf("encode: %v", err)
	}

	// 期望：3 行 progress 事件 + 1 行最终响应（JSON Lines 帧 + 进度穿插）。
	const wantMessages = 4
	gotProgress := 0
	var lastResult map[string]interface{}
	for i := 0; i < wantMessages; i++ {
		var env rpcEnvelope
		if err := dec.Decode(&env); err != nil {
			t.Fatalf("decode msg %d: %v", i, err)
		}
		switch {
		case env.Method == "progress":
			var pe ProgressEvent
			if err := json.Unmarshal(env.Params, &pe); err != nil {
				t.Fatalf("unmarshal progress: %v", err)
			}
			if pe.ReqID != 7 {
				t.Fatalf("progress req_id=%d, want 7", pe.ReqID)
			}
			gotProgress++
		case env.Result != nil:
			if err := json.Unmarshal(env.Result, &lastResult); err != nil {
				t.Fatalf("unmarshal result: %v", err)
			}
		case env.Error != nil:
			t.Fatalf("unexpected error: %+v", env.Error)
		default:
			t.Fatalf("unexpected envelope: %+v", env)
		}
	}
	if gotProgress < 3 {
		t.Fatalf("expected >=3 progress events, got %d", gotProgress)
	}
	if lastResult == nil {
		t.Fatalf("missing final result line")
	}
	if bestIP, ok := lastResult["best_ip_count"].(float64); !ok || int(bestIP) != 3 {
		t.Fatalf("expected best_ip_count==3, got %v", lastResult["best_ip_count"])
	}
}

func TestHistoryList(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	params, err := json.Marshal(map[string]int{"n": 5})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("3"), Method: "history.list", Params: params}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error != nil {
		t.Fatalf("unexpected error: %+v", env.Error)
	}
	var entries []history.HistoryEntry
	if err := json.Unmarshal(env.Result, &entries); err != nil {
		t.Fatalf("unmarshal entries: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
}
