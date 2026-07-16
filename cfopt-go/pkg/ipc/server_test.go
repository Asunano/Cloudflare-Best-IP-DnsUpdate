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

type fakeSyncService struct {
	gotProviders []string
}

func (f *fakeSyncService) Run(ctx context.Context, onProgress sync.ProgressFunc, providers ...string) (*sync.SyncSummary, error) {
	f.gotProviders = append(f.gotProviders, providers...)
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

// TestSyncRunProvidersFilter 验证 sync.run 收到 params.providers 后透传给 SyncService.Run。
func TestSyncRunProvidersFilter(t *testing.T) {
	fakeSync := &fakeSyncService{}
	srv := NewServer(Services{Sync: fakeSync})
	port, err := srv.Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() { _ = srv.Serve() }()
	defer func() { _ = srv.Shutdown(context.Background()) }()

	enc, dec := dialTest(t, port)
	params, err := json.Marshal(map[string][]string{"providers": {"cf"}})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("9"), Method: "sync.run", Params: params}); err != nil {
		t.Fatalf("encode: %v", err)
	}

	// 读取所有帧直到最终响应（progress 事件 + 最终 result）。
	var lastResult map[string]interface{}
	found := false
	for {
		var env rpcEnvelope
		if err := dec.Decode(&env); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if env.Result != nil {
			if err := json.Unmarshal(env.Result, &lastResult); err != nil {
				t.Fatalf("unmarshal result: %v", err)
			}
			found = true
			break
		}
		if env.Error != nil {
			t.Fatalf("unexpected error: %+v", env.Error)
		}
	}
	if !found {
		t.Fatalf("missing final result line")
	}

	// 断言 fake 收到的 providers == ["cf"]。
	if len(fakeSync.gotProviders) != 1 || fakeSync.gotProviders[0] != "cf" {
		t.Fatalf("expected providers [cf], got %v", fakeSync.gotProviders)
	}
}

// TestConfigValidateNoParams 回归：无 params 调用 config.validate 不应再报
// "unexpected end of JSON input"，而应校验当前已加载配置并返回 ok:true。
func TestConfigValidateNoParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("10"), Method: "config.validate"}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error != nil {
		t.Fatalf("unexpected error: %+v", env.Error)
	}
	var res map[string]bool
	if err := json.Unmarshal(env.Result, &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if res["ok"] != true {
		t.Fatalf("expected ok==true, got %v", res["ok"])
	}
}

// TestConfigValidateWithParams 确认带 params 时仍正常校验传入配置。
func TestConfigValidateWithParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	params, err := json.Marshal(map[string]interface{}{"global": map[string]interface{}{}})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("12"), Method: "config.validate", Params: params}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error != nil {
		t.Fatalf("unexpected error: %+v", env.Error)
	}
	var res map[string]bool
	if err := json.Unmarshal(env.Result, &res); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if res["ok"] != true {
		t.Fatalf("expected ok==true, got %v", res["ok"])
	}
}

// TestConfigSaveNoParams 确认无 params 时不再崩在 json.Unmarshal，而是返回无效参数错误。
func TestConfigSaveNoParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("13"), Method: "config.save"}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error == nil {
		t.Fatalf("expected invalid params error, got nil")
	}
	if env.Error.Code != CodeInvalidParams {
		t.Fatalf("expected code %d, got %d", CodeInvalidParams, env.Error.Code)
	}
}

// TestHistoryListNoParams 回归：无 params 调用 history.list 不应崩溃，
// 应沿用默认 n=20 并返回列表。
func TestHistoryListNoParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{JSONRPC: ProtocolVersion, ID: json.RawMessage("11"), Method: "history.list"}); err != nil {
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
	if len(entries) == 0 {
		t.Fatalf("expected non-empty history list, got %d", len(entries))
	}
}

// TestConfigValidateCorruptedParams 边界：带 params 但 JSON 为合法但类型错误的
// 值（此处为字符串而非 Config 对象），json.Unmarshal 应失败并返回 CodeInvalidParams
// （-32602），而非 panic / 500。覆盖「可选 params」分支的损坏输入路径。
func TestConfigValidateCorruptedParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	// 注意：必须是「合法 JSON 值」，否则请求整体无法解析（会变成 parse error）。
	// 这里用 JSON 字符串（合法 JSON），但无法 unmarshal 进 config.Config。
	if err := enc.Encode(Request{
		JSONRPC: ProtocolVersion,
		ID:      json.RawMessage("14"),
		Method:  "config.validate",
		Params:  json.RawMessage(`"this is not a config object"`),
	}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error == nil {
		t.Fatalf("expected invalid params error, got nil")
	}
	if env.Error.Code != CodeInvalidParams {
		t.Fatalf("expected code %d (-32602), got %d", CodeInvalidParams, env.Error.Code)
	}
}

// TestConfigSaveCorruptedParams 边界：config.save 必填 params，但传入合法 JSON 却
// 非 Config 对象时，应返回 CodeInvalidParams（-32602）而非崩溃/500。
func TestConfigSaveCorruptedParams(t *testing.T) {
	port, _, stop := startTestServer(t)
	defer stop()

	enc, dec := dialTest(t, port)
	if err := enc.Encode(Request{
		JSONRPC: ProtocolVersion,
		ID:      json.RawMessage("15"),
		Method:  "config.save",
		Params:  json.RawMessage(`"this is not a config object"`),
	}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	var env rpcEnvelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Error == nil {
		t.Fatalf("expected invalid params error, got nil")
	}
	if env.Error.Code != CodeInvalidParams {
		t.Fatalf("expected code %d (-32602), got %d", CodeInvalidParams, env.Error.Code)
	}
}
