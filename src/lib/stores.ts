// 全局可读状态：当前 sync.run 进度（用于跨页面的进度条/状态提示）。
import { writable } from 'svelte/store';
import type { ProgressEvent, SyncSummary } from './ipc-types';

/** 最近一次 sync.run 的进度事件序列。 */
export const progressEvents = writable<ProgressEvent[]>([]);

/** 当前是否正在同步。 */
export const syncing = writable<boolean>(false);

/** 最近一次 sync.run 的结果汇总。 */
export const lastSummary = writable<SyncSummary | null>(null);

/** 重置进度状态（开始一次新同步前调用）。 */
export function resetProgress(): void {
  progressEvents.set([]);
  lastSummary.set(null);
}
