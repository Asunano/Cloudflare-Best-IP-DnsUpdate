// Tauri 桥接层：把前端的 IPC 调用透传给 Rust 侧 `ipc_request` 命令，
// 并订阅 `sync-progress` 事件（由 Rust 从 Go 守护进程的 progress 通知转发而来）。

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import type { IpcParams, ProgressEvent } from './ipc-types';

/**
 * 统一 IPC 请求入口。
 * @param method 13 个方法之一（如 "sync.run" / "config.get"）
 * @param params 可选 JSON 参数（如 sync.run 的 { providers: [...] }）
 */
export async function ipcRequest<T = unknown>(
  method: string,
  params?: IpcParams,
): Promise<T> {
  return invoke<T>('ipc_request', { method, params: params ?? null });
}

/**
 * 订阅 sync.run 的进度事件。返回的 UnlistenFn 需在组件卸载时调用以移除监听。
 */
export async function onProgress(handler: (e: ProgressEvent) => void): Promise<UnlistenFn> {
  return listen<ProgressEvent>('sync-progress', (event) => handler(event.payload));
}
