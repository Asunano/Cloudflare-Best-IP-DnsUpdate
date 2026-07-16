// IPC 协议类型定义（与 Go `cfopt-go/pkg/ipc` 严格对齐，全部 snake_case）。
// 前端用这些类型解析/构造 invoke('ipc_request', { method, params }) 的入参与结果。

/** JSON-RPC 错误（对应 Go RPCError）。 */
export interface RpcError {
  code: number;
  message: string;
}

/** `version` 返回。 */
export interface VersionInfo {
  version: string;
  commit?: string;
  built_at?: string;
}

/** `daemon.status` 返回。state: running | stopped | unknown */
export interface DaemonStatus {
  state: string;
}

/** `progress` 事件参数。 */
export interface ProgressEvent {
  req_id: number;
  /** speedtest | extract | write | cloudflare | dnspod */
  phase: string;
  cur: number;
  total: number;
  message?: string;
}

/** `sync.run` 返回的执行汇总。 */
export interface SyncSummary {
  best_ip_count: number;
  updated: number;
  created: number;
  deleted: number;
  errors: string[];
}

/** `speedtest.run` 返回的单条测速结果。 */
export interface SpeedResult {
  ip: string;
  sent: number;
  received: number;
  loss: number;
  latency: number;
  speed: number;
  colo: string;
}

/** `history.list` 返回的单条历史记录。 */
export interface HistoryEntry {
  ts: string;
  action: string;
  detail: string;
  success: boolean;
}

// ============================= 配置类型 =============================
// 与 Go `internal/config` 模型对齐。全部字段可选以支持部分编辑与缺失回落。

export interface GlobalConfig {
  root_dir?: string;
  log_dir?: string;
  log_level?: string;
  lock_dir?: string;
  data_dir?: string;
  cache_dir?: string;
  bin_dir?: string;
  schedule?: ScheduleConfig;
}

export interface ScheduleConfig {
  interval?: string;
}

export interface CFIPConfig {
  enabled?: boolean;
  cfst?: CFSTConfig;
  speed_test?: SpeedTestConfig;
  paths?: PathConfig;
  cfst_path?: string;
}

export interface CFSTConfig {
  directory?: string;
  binary?: string;
  threads?: number;
  colo?: string;
  ping_times?: number;
  download_count?: number;
  download_time?: number;
  port?: number;
  url?: string;
  httping?: boolean;
  latency_max?: number;
  packet_loss_max?: number;
  speed_min?: number;
  show_count?: number;
  ip_file?: string;
  disable_download?: boolean;
  all_ip?: boolean;
}

export interface SpeedTestConfig {
  take_ip_num?: number;
  max_retry?: number;
  output_html?: boolean;
  enable_log?: boolean;
}

export interface PathConfig {
  output_dir?: string;
  log_dir?: string;
}

export interface CFDNSConfig {
  enabled?: boolean;
  api?: CloudflareAPIConfig;
  dns?: CloudflareDNSConfig;
  ip_source?: CloudflareIPSourceConfig;
  logging?: CloudflareLoggingConfig;
}

export interface CloudflareAPIConfig {
  token?: string;
  zone_id?: string;
  timeout?: number;
  max_retries?: number;
}

export interface CloudflareDNSConfig {
  record_name?: string;
  domain?: string;
  max_ips_per_record?: number;
}

export interface CloudflareIPSourceConfig {
  file_path?: string;
  auto_refresh?: boolean;
  refresh_interval_hours?: number;
}

export interface CloudflareLoggingConfig {
  log_dir?: string;
  log_rotation_days?: number;
  verbose?: boolean;
}

export interface ISPConf {
  domains?: string[];
  ip_source?: ISPipSource;
}

export interface ISPipSource {
  /** key=运营商(默认/联通/移动/电信) → IP 文件路径 */
  files?: Record<string, string>;
}

export interface DNSPodConfig {
  enabled?: boolean;
  secret_id?: string;
  secret_key?: string;
  mode?: string;
  isp_lines?: Record<string, ISPConf>;
  domain?: string;
  ttl?: number;
  max_ips_per_record?: number;
  sub_domain?: string;
  sub_domain_unified?: string;
  sub_domains?: Record<string, string>;
  ip_file?: string;
  log_dir?: string;
  timeout?: number;
  max_retries?: number;
}

/** 顶层配置（对应 Go config.Config）。 */
export interface Config {
  global?: GlobalConfig;
  cf_ip?: CFIPConfig;
  cf_dns?: CFDNSConfig;
  dnspod?: DNSPodConfig;
  modules?: Record<string, unknown>;
}

/** invoke('ipc_request') 的 params 入参（任意 JSON 对象或 null）。 */
export type IpcParams = Record<string, unknown> | null;
