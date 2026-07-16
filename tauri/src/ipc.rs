//! IPC 客户端：与 Go 端 `pkg/ipc` JSON-RPC 服务通信。
//!
//! 传输：TCP loopback（127.0.0.1:<port>），JSON-RPC 2.0 语义，JSON Lines 帧
//! （每个 JSON 值独占一行，以 `'\n'` 结尾）。
//!
//! 约定（与 `cfopt-go/pkg/ipc/protocol.go` 严格对齐）：
//! - 所有枚举/结构体字段均为 snake_case；
//! - `id` 为整数（Go 端按 int64 解析）；
//! - `sync.run` 执行期间，服务端会在最终响应之前，于同一连接上穿插推送
//!   `progress` 通知（method=="progress"），由 [`ProgressEvent.req_id`] 关联回请求。
//!
//! Rust 侧零业务逻辑：仅做透传序列化、连接管理与进度事件转发。

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

/// 连接读超时。`sync.run` 可能耗时较长，给足 5 分钟。
const READ_TIMEOUT: Duration = Duration::from_secs(300);

/// IPC 调用结果：成功返回 JSON 值，失败返回可读错误字符串。
pub type IpcResult<T> = Result<T, String>;

// ============================= 协议类型 =============================

/// JSON-RPC 错误（与 Go `RPCError` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// `version` 方法返回（与 Go `VersionInfo` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionInfo {
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub built_at: Option<String>,
}

/// `daemon.status` 方法返回（与 Go `DaemonStatus` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatus {
    /// running | stopped | unknown
    pub state: String,
}

/// `progress` 事件参数（与 Go `ProgressEvent` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProgressEvent {
    pub req_id: i64,
    /// speedtest | extract | write | cloudflare | dnspod
    pub phase: String,
    pub cur: i64,
    pub total: i64,
    #[serde(default)]
    pub message: String,
}

/// `sync.run` 返回的执行汇总（与 Go `SyncSummary` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSummary {
    pub best_ip_count: i64,
    pub updated: i64,
    pub created: i64,
    pub deleted: i64,
    #[serde(default)]
    pub errors: Vec<String>,
}

/// `speedtest.run` 返回的单条测速结果（与 Go `SpeedResult` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpeedResult {
    pub ip: String,
    pub sent: i64,
    pub received: i64,
    pub loss: f64,
    pub latency: f64,
    pub speed: f64,
    pub colo: String,
}

/// `history.list` 返回的单条历史记录（与 Go `HistoryEntry` 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub ts: String,
    pub action: String,
    pub detail: String,
    pub success: bool,
}

// ============================= 配置类型 =============================
// 与 Go `internal/config` 模型严格对齐（snake_case，全部字段可选以支持部分编辑）。
// 反序列化时缺失字段回落为 None；序列化时跳过 None，避免清空未编辑的值。

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct GlobalConfig {
    pub root_dir: Option<String>,
    pub log_dir: Option<String>,
    pub log_level: Option<String>,
    pub lock_dir: Option<String>,
    pub data_dir: Option<String>,
    pub cache_dir: Option<String>,
    pub bin_dir: Option<String>,
    pub schedule: Option<ScheduleConfig>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct ScheduleConfig {
    /// Go duration 字符串，如 "6h"；空则默认 6h。
    pub interval: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CFIPConfig {
    pub enabled: Option<bool>,
    pub cfst: Option<CFSTConfig>,
    pub speed_test: Option<SpeedTestConfig>,
    pub paths: Option<PathConfig>,
    pub cfst_path: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CFSTConfig {
    pub directory: Option<String>,
    pub binary: Option<String>,
    pub threads: Option<i64>,
    pub colo: Option<String>,
    pub ping_times: Option<i64>,
    pub download_count: Option<i64>,
    pub download_time: Option<i64>,
    pub port: Option<i64>,
    pub url: Option<String>,
    pub httping: Option<bool>,
    pub latency_max: Option<f64>,
    pub packet_loss_max: Option<f64>,
    pub speed_min: Option<f64>,
    pub show_count: Option<i64>,
    pub ip_file: Option<String>,
    pub disable_download: Option<bool>,
    pub all_ip: Option<bool>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct SpeedTestConfig {
    pub take_ip_num: Option<i64>,
    pub max_retry: Option<i64>,
    pub output_html: Option<bool>,
    pub enable_log: Option<bool>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct PathConfig {
    pub output_dir: Option<String>,
    pub log_dir: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CFDNSConfig {
    pub enabled: Option<bool>,
    pub api: Option<CloudflareAPIConfig>,
    pub dns: Option<CloudflareDNSConfig>,
    pub ip_source: Option<CloudflareIPSourceConfig>,
    pub logging: Option<CloudflareLoggingConfig>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CloudflareAPIConfig {
    pub token: Option<String>,
    pub zone_id: Option<String>,
    pub timeout: Option<i64>,
    pub max_retries: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CloudflareDNSConfig {
    /// 子域名：dns/cf/@(根域名)
    pub record_name: Option<String>,
    pub domain: Option<String>,
    pub max_ips_per_record: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CloudflareIPSourceConfig {
    pub file_path: Option<String>,
    pub auto_refresh: Option<bool>,
    pub refresh_interval_hours: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct CloudflareLoggingConfig {
    pub log_dir: Option<String>,
    pub log_rotation_days: Option<i64>,
    pub verbose: Option<bool>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct ISPConf {
    pub domains: Option<Vec<String>>,
    pub ip_source: Option<ISPipSource>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct ISPipSource {
    /// key=运营商(默认/联通/移动/电信) → IP 文件路径（.iplist/.csv/.txt）
    pub files: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct DNSPodConfig {
    pub enabled: Option<bool>,
    pub secret_id: Option<String>,
    pub secret_key: Option<String>,
    /// single | isp_lines
    pub mode: Option<String>,
    /// key=线路名(默认/联通/移动/电信)
    pub isp_lines: Option<HashMap<String, ISPConf>>,
    // 单线路兼容字段（mode=single 时使用）
    pub domain: Option<String>,
    pub ttl: Option<i64>,
    pub max_ips_per_record: Option<i64>,
    pub sub_domain: Option<String>,
    pub sub_domain_unified: Option<String>,
    pub sub_domains: Option<HashMap<String, String>>,
    pub ip_file: Option<String>,
    pub log_dir: Option<String>,
    pub timeout: Option<i64>,
    pub max_retries: Option<i64>,
}

/// 顶层配置（与 Go `config.Config` 对齐）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", default)]
pub struct Config {
    pub global: Option<GlobalConfig>,
    pub cf_ip: Option<CFIPConfig>,
    pub cf_dns: Option<CFDNSConfig>,
    pub dnspod: Option<DNSPodConfig>,
    /// 各外部 DNS 提供方（如 aliyun）的自有配置（透传，不在此建模）。
    pub modules: Option<Value>,
}

// ============================= IpcClient =============================

/// IPC 客户端：维护到 Go 守护进程的地址；每次调用新建一条 TCP 连接
/// （Go 服务端按连接串行处理请求，单连接可承载一请求及其 progress 事件流）。
#[derive(Debug, Clone)]
pub struct IpcClient {
    addr: String,
    next_id: AtomicI64,
}

impl IpcClient {
    /// 构造客户端。addr 形如 "127.0.0.1:54321"。
    pub fn new(addr: impl Into<String>) -> Self {
        Self {
            addr: addr.into(),
            next_id: AtomicI64::new(1),
        }
    }

    /// 更新守护进程地址（端口发现后调用）。
    pub fn set_addr(&mut self, addr: impl Into<String>) {
        self.addr = addr.into();
    }

    /// 分配自增请求 id（整数，与 Go 端 parseID 一致）。
    fn alloc_id(&self) -> i64 {
        self.next_id.fetch_add(1, Ordering::SeqCst)
    }

    /// 发送一次 JSON-RPC 请求并读取响应（无 progress 事件）。
    pub fn call<P: Serialize>(&self, method: &str, params: Option<&P>) -> IpcResult<Value> {
        self.call_inner(method, params, None)
    }

    /// 发送请求并消费 progress 事件（`sync.run` 时使用），最终返回 result。
    pub fn call_with_progress<P, F>(
        &self,
        method: &str,
        params: Option<&P>,
        on_progress: F,
    ) -> IpcResult<Value>
    where
        P: Serialize,
        F: Fn(ProgressEvent),
    {
        self.call_inner(method, params, Some(&on_progress))
    }

    /// 内部通用实现：写请求 → 逐行读帧，progress 事件交给回调，命中 id 的响应作为结果返回。
    fn call_inner<P>(
        &self,
        method: &str,
        params: Option<&P>,
        on_progress: Option<&dyn Fn(ProgressEvent)>,
    ) -> IpcResult<Value>
    where
        P: Serialize,
    {
        let id = self.alloc_id();
        let params_value: Value = match params {
            Some(p) => serde_json::to_value(p).map_err(|e| format!("参数序列化失败: {e}"))?,
            None => Value::Null,
        };
        let req = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params_value,
        });

        let mut stream = TcpStream::connect(&self.addr)
            .map_err(|e| format!("无法连接 IPC 服务 {}: {}", self.addr, e))?;
        stream.set_read_timeout(Some(READ_TIMEOUT)).ok();

        let payload =
            serde_json::to_string(&req).map_err(|e| format!("请求序列化失败: {e}"))?;
        stream
            .write_all(payload.as_bytes())
            .and_then(|_| stream.write_all(b"\n"))
            .and_then(|_| stream.flush())
            .map_err(|e| format!("发送请求失败: {e}"))?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        loop {
            line.clear();
            let n = reader
                .read_line(&mut line)
                .map_err(|e| format!("读取响应失败: {e}"))?;
            if n == 0 {
                return Err("IPC 连接关闭，未收到完整响应".into());
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let frame: Value = serde_json::from_str(trimmed)
                .map_err(|e| format!("解析帧失败: {e} (raw: {trimmed})"))?;

            // 通知（progress 事件）：无 id，且 method=="progress"
            let is_event = frame.get("method").and_then(Value::as_str) == Some("progress");
            if is_event {
                if let Some(cb) = on_progress {
                    if let Some(p) = frame.get("params") {
                        if let Ok(pe) = serde_json::from_value::<ProgressEvent>(p.clone()) {
                            cb(pe);
                        }
                    }
                }
                continue;
            }

            // 响应：含 id
            if frame.get("id").is_some() {
                if let Some(err) = frame.get("error") {
                    let code = err.get("code").and_then(Value::as_i64).unwrap_or(-32603);
                    let msg = err
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown error")
                        .to_string();
                    return Err(format!("IPC 错误 [{code}]: {msg}"));
                }
                return Ok(frame.get("result").cloned().unwrap_or(Value::Null));
            }
            // 其他帧忽略（保留扩展兼容性）
        }
    }

    // ============ 13 个类型化方法（与 Go `dispatch` 一一对应） ============

    pub fn ping(&self) -> IpcResult<bool> {
        let v = self.call::<()>("ping", None)?;
        Ok(v.get("pong").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn version(&self) -> IpcResult<VersionInfo> {
        let v = self.call::<()>("version", None)?;
        serde_json::from_value(v).map_err(|e| format!("解析 version 失败: {e}"))
    }

    pub fn config_get(&self) -> IpcResult<Config> {
        let v = self.call::<()>("config.get", None)?;
        serde_json::from_value(v).map_err(|e| format!("解析 config 失败: {e}"))
    }

    pub fn config_validate(&self, cfg: &Config) -> IpcResult<bool> {
        let v = self.call("config.validate", Some(cfg))?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn config_save(&self, cfg: &Config) -> IpcResult<bool> {
        let v = self.call("config.save", Some(cfg))?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    /// 一键同步。`providers` 非空时仅同步指定且启用的模块（向后兼容）。
    pub fn sync_run<F: Fn(ProgressEvent)>(
        &self,
        providers: Option<Vec<String>>,
        on_progress: F,
    ) -> IpcResult<SyncSummary> {
        let params = match providers {
            Some(p) if !p.is_empty() => json!({ "providers": p }),
            _ => json!({}),
        };
        let v = self.call_with_progress("sync.run", Some(&params), on_progress)?;
        serde_json::from_value(v).map_err(|e| format!("解析 sync 汇总失败: {e}"))
    }

    pub fn speedtest_run(&self) -> IpcResult<Vec<SpeedResult>> {
        let v = self.call::<()>("speedtest.run", None)?;
        serde_json::from_value(v).map_err(|e| format!("解析 speedtest 失败: {e}"))
    }

    pub fn history_list(&self, n: i64) -> IpcResult<Vec<HistoryEntry>> {
        let params = json!({ "n": n });
        let v = self.call("history.list", Some(&params))?;
        serde_json::from_value(v).map_err(|e| format!("解析 history 失败: {e}"))
    }

    pub fn daemon_install(&self) -> IpcResult<bool> {
        let v = self.call::<()>("daemon.install", None)?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn daemon_uninstall(&self) -> IpcResult<bool> {
        let v = self.call::<()>("daemon.uninstall", None)?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn daemon_start(&self) -> IpcResult<bool> {
        let v = self.call::<()>("daemon.start", None)?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn daemon_stop(&self) -> IpcResult<bool> {
        let v = self.call::<()>("daemon.stop", None)?;
        Ok(v.get("ok").and_then(Value::as_bool).unwrap_or(false))
    }

    pub fn daemon_status(&self) -> IpcResult<DaemonStatus> {
        let v = self.call::<()>("daemon.status", None)?;
        serde_json::from_value(v).map_err(|e| format!("解析 daemon.status 失败: {e}"))
    }
}
