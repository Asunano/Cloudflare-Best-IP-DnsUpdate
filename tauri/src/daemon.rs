//! Go 守护进程（sidecar）生命周期管理：spawn + 端口发现 + 停止。
//!
//! 启动方式：`cfopt-go serve --ipc-addr 127.0.0.1:0 --ipc-port-file <path> [--config-dir <dir>]`
//! Go 端以 tmp+rename 原子写把实际端口写入 `<path>`（单行整数），Rust 侧轮询读取完成发现。

use crate::ipc::IpcClient;
use crate::AppState;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, State};
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

/// 守护进程句柄：持有 sidecar 子进程、端口文件路径与可选的 config-dir。
pub struct DaemonManager {
    child: Option<CommandChild>,
    port_file: PathBuf,
    config_dir: Option<String>,
}

impl DaemonManager {
    pub fn new(port_file: PathBuf, config_dir: Option<String>) -> Self {
        Self {
            child: None,
            port_file,
            config_dir,
        }
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    pub fn port_file(&self) -> &PathBuf {
        &self.port_file
    }

    pub fn config_dir(&self) -> Option<&str> {
        self.config_dir.as_deref()
    }

    pub fn set_child(&mut self, child: CommandChild) {
        self.child = Some(child);
    }
}

/// 拉起 Go sidecar，返回其进程句柄。
fn spawn_sidecar(
    app: &AppHandle,
    port_file: &Path,
    config_dir: Option<&str>,
) -> Result<CommandChild, String> {
    let mut command = app
        .shell()
        .sidecar("cfopt-go")
        .map_err(|e| format!("获取 sidecar 句柄失败: {e}"))?;

    let mut args: Vec<String> = vec![
        "serve".into(),
        "--ipc-addr".into(),
        "127.0.0.1:0".into(),
        "--ipc-port-file".into(),
        port_file.to_string_lossy().to_string(),
    ];
    if let Some(dir) = config_dir {
        args.push("--config-dir".into());
        args.push(dir.to_string());
    }

    let (mut rx, child) = command
        .args(args)
        .spawn()
        .map_err(|e| format!("启动 Go 守护进程失败: {e}"))?;

    // 后台消费 sidecar 的 stdout/stderr 事件，避免通道阻塞（此处仅占位，生产可桥接日志）。
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(_bytes) | CommandEvent::Stderr(_bytes) => {}
                _ => {}
            }
        }
    });

    Ok(child)
}

/// 轮询端口文件（Go 端以 tmp+rename 原子写，读到即完整），超时返回错误。
fn read_port_with_retry(path: &Path, timeout: Duration) -> Result<u16, String> {
    let start = Instant::now();
    let mut backoff = Duration::from_millis(100);
    loop {
        if let Ok(s) = std::fs::read_to_string(path) {
            let s = s.trim();
            if let Ok(port) = s.parse::<u16>() {
                return Ok(port);
            }
        }
        if start.elapsed() > timeout {
            return Err(format!("等待 Go 守护进程端口文件超时: {}", path.display()));
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(1));
    }
}

/// 确保 Go 守护进程已启动且端口已发现；随后把地址写入 [`IpcClient`]。
///
/// 幂等：已连接则直接返回；未运行则拉起 sidecar 并等待端口文件。
pub fn ensure_daemon(app: &AppHandle, state: &State<AppState>) -> Result<(), String> {
    // 快速探活：若现有连接 ping 成功，直接复用。
    {
        let client = state
            .client
            .lock()
            .map_err(|_| "client 锁竞争".to_string())?;
        if client.ping().unwrap_or(false) {
            return Ok(());
        }
    }

    // 加锁后判断是否已拉起（避免并发重复 spawn）。
    let mut dm = state
        .daemon
        .lock()
        .map_err(|_| "daemon 锁竞争".to_string())?;
    if !dm.is_running() {
        let pf = dm.port_file().clone();
        let cd = dm.config_dir().map(|s| s.to_string());
        let child = spawn_sidecar(app, &pf, cd.as_deref())?;
        dm.set_child(child);
    }

    // 等待端口文件并配置客户端地址。
    let port = read_port_with_retry(dm.port_file(), Duration::from_secs(15))?;
    drop(dm);
    let mut client = state
        .client
        .lock()
        .map_err(|_| "client 锁竞争".to_string())?;
    *client = IpcClient::new(format!("127.0.0.1:{port}"));
    Ok(())
}

/// 停止 Go 守护进程（若已运行）。
pub fn stop_daemon(state: &State<AppState>) -> Result<(), String> {
    let mut dm = state
        .daemon
        .lock()
        .map_err(|_| "daemon 锁竞争".to_string())?;
    if let Some(mut child) = dm.child.take() {
        child.kill().map_err(|e| format!("停止守护进程失败: {e}"))?;
    }
    Ok(())
}
