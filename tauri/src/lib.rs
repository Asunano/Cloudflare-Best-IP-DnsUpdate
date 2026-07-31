//! cfopt 桌面端 Rust 入口：Tauri v2 应用 + IPC 桥接层。
//!
//! 设计原则：Rust 侧零业务逻辑，
//! 仅做 UI 渲染、参数透传与 IPC 桥接；所有优选/测速/DNS 同步均在 Go 端完成。
//!
//! 前端（SvelteKit）通过 `invoke('ipc_request', { method, params })` 发起调用，
//! 本模块将其转发给 [`ipc::IpcClient`]，并把 `sync.run` / `speedtest.run` 的 progress 事件
//! 以 `sync-progress` / `speedtest-progress` 事件透传给前端。
//!
//! 另有 [`cli::run_cli`] 命令：对只有 CLI 实现、未暴露 IPC 方法的能力
//! （health / logs / cfst / schedule 等），直接以子进程方式运行同一个 sidecar 二进制，
//! 输出经 `cli-log` / `cli-exit` 事件流式回传。

mod cli;
mod daemon;
mod ipc;

use daemon::{DaemonManager, ensure_daemon, resolve_config_dir, stop_daemon};
use ipc::{Config, IpcClient, ProgressEvent};
use serde_json::{Value, json};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

/// 跨命令共享的应用状态：IPC 客户端 + 守护进程句柄。
pub struct AppState {
    client: Mutex<IpcClient>,
    daemon: Mutex<DaemonManager>,
}

/// 前端统一入口：method 指定 13 个 IPC 方法之一，params 为可选 JSON 参数。
#[tauri::command]
fn ipc_request(
    app: AppHandle,
    state: State<AppState>,
    method: String,
    params: Option<Value>,
) -> Result<Value, String> {
    // 确保 Go 守护进程已启动并发现端口。
    ensure_daemon(&app, &state)?;

    let client = state
        .client
        .lock()
        .map_err(|_| "client 锁竞争".to_string())?;

    let result: Value = match method.as_str() {
        "ping" => json!({ "pong": client.ping()? }),
        "version" => serde_json::to_value(client.version()?).unwrap_or(Value::Null),
        "config.get" => serde_json::to_value(client.config_get()?).unwrap_or(Value::Null),
        "config.validate" => {
            let cfg: Config = params
                .and_then(|p| serde_json::from_value(p).ok())
                .ok_or("config.validate 缺少 config 参数")?;
            json!({ "ok": client.config_validate(&cfg)? })
        }
        "config.save" => {
            let cfg: Config = params
                .and_then(|p| serde_json::from_value(p).ok())
                .ok_or("config.save 缺少 config 参数")?;
            json!({ "ok": client.config_save(&cfg)? })
        }
        "sync.run" => {
            let providers: Option<Vec<String>> = params.as_ref().and_then(|p| {
                p.get("providers")
                    .and_then(|v| serde_json::from_value::<Vec<String>>(v.clone()).ok())
            });
            let summary = client.sync_run(providers, |pe: ProgressEvent| {
                let _ = app.emit("sync-progress", pe);
            })?;
            serde_json::to_value(summary).unwrap_or(Value::Null)
        }
        "speedtest.run" => {
            let results = client.speedtest_run(|pe: ProgressEvent| {
                let _ = app.emit("speedtest-progress", pe);
            })?;
            serde_json::to_value(results).unwrap_or(Value::Null)
        }
        "history.list" => {
            let n = params
                .as_ref()
                .and_then(|p| p.get("n").and_then(Value::as_i64))
                .unwrap_or(20);
            serde_json::to_value(client.history_list(n)?).unwrap_or(Value::Null)
        }
        "daemon.install" => json!({ "ok": client.daemon_install()? }),
        "daemon.uninstall" => json!({ "ok": client.daemon_uninstall()? }),
        "daemon.start" => json!({ "ok": client.daemon_start()? }),
        "daemon.stop" => json!({ "ok": client.daemon_stop()? }),
        "daemon.status" => {
            serde_json::to_value(client.daemon_status()?).unwrap_or(Value::Null)
        }
        other => return Err(format!("不支持的 IPC 方法: {other}")),
    };
    Ok(result)
}

/// 停止 Go 守护进程（供前端「停止守护进程」按钮调用）。
#[tauri::command]
fn stop_daemon_cmd(state: State<AppState>) -> Result<(), String> {
    stop_daemon(&state)
}

/// 应用入口。构建 AppState 并注册命令。
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            // 端口发现文件：优先应用数据目录，回退到临时目录。
            let port_file = match app.path().app_data_dir() {
                Ok(d) => {
                    let _ = std::fs::create_dir_all(&d);
                    d.join("cfopt-ipc.port")
                }
                Err(_) => std::env::temp_dir().join("cfopt-ipc.port"),
            };
            let config_dir = resolve_config_dir();
            app.manage(AppState {
                client: Mutex::new(IpcClient::new("127.0.0.1:0")),
                daemon: Mutex::new(DaemonManager::new(port_file, config_dir)),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ipc_request,
            stop_daemon_cmd,
            cli::run_cli
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
