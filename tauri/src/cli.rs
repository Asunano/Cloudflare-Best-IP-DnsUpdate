//! CLI 直通层：以子进程方式运行 Go sidecar 的普通子命令，并把输出流式推给前端。
//!
//! 为什么不走 IPC：`health` / `logs` / `cfst` / `schedule` 等能力在 Go 端只有 CLI 实现，
//! 走 IPC 需要同时改 Go 服务端、协议契约测试、Rust 桥接、TS 类型四处。
//! 这里直接复用同一个 sidecar 二进制，零协议改动。
//!
//! 安全约束：
//! 1. 子命令白名单（禁止 `serve`，避免与守护进程抢端口）；
//! 2. 禁止调用方自带 `--config-dir`，一律由本层注入与守护进程相同的配置目录；
//! 3. 超时强杀。

use crate::AppState;
use serde::Serialize;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

/// 允许从 GUI 触发的顶层子命令白名单（第一个位置参数必须命中）。
///
/// 刻意不含：
/// - `serve`（与守护进程抢端口）；
/// - `list`（该 CLI 命令并不存在，只是主菜单回调）；
/// - `quickdeploy`（纯交互向导，非 TTY 下只会打印提示，GUI 自建表单代替）；
/// - `menu` / 无参启动（交互菜单）。
const ALLOWED: &[&str] = &[
    "health",
    "logs",
    "update",
    "cfst",
    "config",
    "install",
    "uninstall",
    "schedule",
    "version",
    "dns",
    "speedtest",
];

/// 二级黑名单：这些组合在非 TTY 下要么死循环，要么常驻不退出。
///
/// - `config cfip`：不带域名时 `AskChoice` 读到 EOF 会无限刷「无效输入」；
/// - `config wizard` / `dns dnspod switch`：交互向导，非 TTY 只打印提示；
/// - `schedule run`：不带 `--once` 会常驻 daemon 永不返回（由 `requires_once` 单独兜底）。
const DENIED_PAIRS: &[(&str, &str)] = &[("config", "cfip"), ("config", "wizard")];

/// 默认超时（秒）：测速类命令可能较久，调用方可覆盖。
const DEFAULT_TIMEOUT_SECS: u64 = 600;

/// 一次 CLI 执行的最终结果。字段与 `src/lib/ipc-types.ts` 的 `CliResult` 对齐。
#[derive(Debug, Clone, Serialize)]
pub struct CliResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

/// 单行日志事件载荷（事件名 `cli-log`）。
#[derive(Debug, Clone, Serialize)]
struct CliLogEvent {
    run_id: String,
    stream: &'static str,
    line: String,
}

/// 退出事件载荷（事件名 `cli-exit`）。
#[derive(Debug, Clone, Serialize)]
struct CliExitEvent {
    run_id: String,
    exit_code: i32,
    timed_out: bool,
}

/// 校验参数：非空、首参在白名单内、不命中黑名单、不含被本层接管的全局 flag。
fn validate(args: &[String]) -> Result<(), String> {
    let positional: Vec<&str> = args
        .iter()
        .filter(|a| !a.starts_with('-'))
        .map(|s| s.as_str())
        .collect();
    let first = *positional.first().ok_or("缺少子命令")?;
    if !ALLOWED.contains(&first) {
        return Err(format!("不允许从界面执行的子命令: {first}"));
    }
    if let Some(second) = positional.get(1) {
        if DENIED_PAIRS.contains(&(first, second)) {
            return Err(format!("`{first} {second}` 是交互式命令，无法在界面中执行"));
        }
        // dns dnspod switch：交互向导
        if first == "dns" && *second == "dnspod" && positional.get(2) == Some(&"switch") {
            return Err("`dns dnspod switch` 是交互式命令，请在配置页直接修改".into());
        }
    }
    // schedule run 不带 --once 会常驻，永不返回。
    if first == "schedule"
        && positional.get(1) == Some(&"run")
        && !args.iter().any(|a| a == "--once")
    {
        return Err("`schedule run` 必须带 --once，否则会常驻不退出".into());
    }
    if args
        .iter()
        .any(|a| a == "--config-dir" || a.starts_with("--config-dir="))
    {
        return Err("--config-dir 由应用统一注入，请勿手动传入".into());
    }
    Ok(())
}

/// 运行一条 cfopt CLI 命令。
///
/// - `run_id`：前端生成的本次执行标识，用于区分并发运行的日志流；
/// - `args`：子命令及其参数（不含程序名，不含 `--config-dir`）；
/// - `timeout_secs`：可选超时，默认 [`DEFAULT_TIMEOUT_SECS`]。
///
/// 执行期间按行发出 `cli-log` 事件，结束时发出 `cli-exit`，同时返回完整结果。
#[tauri::command]
pub async fn run_cli(
    app: AppHandle,
    state: State<'_, AppState>,
    run_id: String,
    args: Vec<String>,
    timeout_secs: Option<u64>,
) -> Result<CliResult, String> {
    validate(&args)?;

    // 与守护进程共用同一个配置目录（单一真相来源：DaemonManager）。
    let config_dir = {
        let dm = state
            .daemon
            .lock()
            .map_err(|_| "daemon 锁竞争".to_string())?;
        dm.config_dir().map(|s| s.to_string())
    };

    let mut full: Vec<String> = args;
    if let Some(dir) = config_dir {
        full.push("--config-dir".into());
        full.push(dir);
    }

    let command = app
        .shell()
        .sidecar("cfopt-go")
        .map_err(|e| format!("获取 sidecar 句柄失败: {e}"))?
        .args(full);

    let (mut rx, child) = command
        .spawn()
        .map_err(|e| format!("启动 cfopt 命令失败: {e}"))?;
    let mut child: Option<CommandChild> = Some(child);

    let budget = Duration::from_secs(timeout_secs.unwrap_or(DEFAULT_TIMEOUT_SECS));
    let start = Instant::now();
    let mut stdout = String::new();
    let mut stderr = String::new();
    let mut exit_code = -1i32;
    let mut timed_out = false;

    loop {
        let remaining = match budget.checked_sub(start.elapsed()) {
            Some(d) if !d.is_zero() => d,
            _ => {
                timed_out = true;
                break;
            }
        };
        match tokio::time::timeout(remaining, rx.recv()).await {
            Err(_) => {
                timed_out = true;
                break;
            }
            Ok(None) => break,
            Ok(Some(event)) => match event {
                CommandEvent::Stdout(bytes) => {
                    let line = String::from_utf8_lossy(&bytes).trim_end().to_string();
                    stdout.push_str(&line);
                    stdout.push('\n');
                    let _ = app.emit(
                        "cli-log",
                        CliLogEvent {
                            run_id: run_id.clone(),
                            stream: "stdout",
                            line,
                        },
                    );
                }
                CommandEvent::Stderr(bytes) => {
                    let line = String::from_utf8_lossy(&bytes).trim_end().to_string();
                    stderr.push_str(&line);
                    stderr.push('\n');
                    let _ = app.emit(
                        "cli-log",
                        CliLogEvent {
                            run_id: run_id.clone(),
                            stream: "stderr",
                            line,
                        },
                    );
                }
                CommandEvent::Terminated(payload) => {
                    exit_code = payload.code.unwrap_or(-1);
                }
                _ => {}
            },
        }
    }

    if timed_out {
        if let Some(c) = child.take() {
            let _ = c.kill();
        }
        let msg = format!("命令超时（{}s），已终止", budget.as_secs());
        stderr.push_str(&msg);
        stderr.push('\n');
        let _ = app.emit(
            "cli-log",
            CliLogEvent {
                run_id: run_id.clone(),
                stream: "stderr",
                line: msg,
            },
        );
    }

    let _ = app.emit(
        "cli-exit",
        CliExitEvent {
            run_id,
            exit_code,
            timed_out,
        },
    );

    Ok(CliResult {
        exit_code,
        stdout,
        stderr,
        timed_out,
    })
}
