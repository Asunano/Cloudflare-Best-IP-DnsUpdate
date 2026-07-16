// Package ipc 实现 cfopt 与 GUI（Tauri/Rust sidecar）之间的进程间通信协议。
//
// 传输：TCP loopback（默认 127.0.0.1:0 随机端口），JSON-RPC 2.0 语义，
// 帧格式为 JSON Lines —— 每个 JSON 值独占一行，以 '\n' 结尾。
// 请求与响应一一对应；sync.run 执行期间，服务端会在最终 response 之前，
// 于同一连接上穿插推送 progress 事件（method=="progress" 的通知）。
package ipc

import "encoding/json"

// ProtocolVersion 协议版本（JSON-RPC 2.0）。
const ProtocolVersion = "2.0"

// 错误码（JSON-RPC 标准码 + 业务约定）。
const (
	CodeParseError     = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternalError  = -32603
)

// Request 表示一条 JSON-RPC 请求。
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Response 表示一条 JSON-RPC 响应（Result 与 Error 互斥）。
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// RPCError 标准 JSON-RPC 错误结构。
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Error 使 *RPCError 满足 error 接口，便于在 dispatch 中作为 error 返回与类型断言。
func (e *RPCError) Error() string { return e.Message }

// Event 服务端主动向客户端推送的消息（如 progress）。本身为通知、无 id，
// 通过 Params 内的 ReqID 关联回发起请求的客户端连接与请求。
type Event struct {
	JSONRPC string      `json:"jsonrpc"`
	Method  string      `json:"method"` // 当前仅 "progress"
	Params  interface{} `json:"params"`
}

// ProgressEvent 是 progress 事件的参数。
type ProgressEvent struct {
	ReqID   int64  `json:"req_id"`             // 关联请求 id（由服务端解析）
	Phase   string `json:"phase"`             // speedtest/extract/write/cloudflare/dnspod
	Cur     int    `json:"cur"`               // 已完成阶段计数
	Total   int    `json:"total"`             // 总阶段计数
	Message string `json:"message,omitempty"` // 可选可读信息
}

// VersionInfo 是 version 方法的返回。
type VersionInfo struct {
	Version string `json:"version"`
	Commit  string `json:"commit,omitempty"`
	BuiltAt string `json:"built_at,omitempty"`
}

// DaemonStatus 是 daemon.status 方法的返回。
type DaemonStatus struct {
	State string `json:"state"` // running | stopped | unknown
}
