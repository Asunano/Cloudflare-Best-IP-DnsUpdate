// 类型化 API 封装：对 13 个 IPC 方法提供带类型的便捷函数。
// 页面通过 `import { api } from '$lib/api'` 调用，避免散落 method 字符串。

import { ipcRequest } from './tauri';
import type {
  Config,
  DaemonStatus,
  HistoryEntry,
  SpeedResult,
  SyncSummary,
  VersionInfo,
} from './ipc-types';

export const api = {
  ping(): Promise<{ pong: boolean }> {
    return ipcRequest<{ pong: boolean }>('ping');
  },

  version(): Promise<VersionInfo> {
    return ipcRequest<VersionInfo>('version');
  },

  configGet(): Promise<Config> {
    return ipcRequest<Config>('config.get');
  },

  configValidate(cfg: Config): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('config.validate', { ...cfg });
  },

  configSave(cfg: Config): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('config.save', { ...cfg });
  },

  /** providers 非空时仅同步指定且启用的模块（向后兼容）。 */
  syncRun(providers?: string[]): Promise<SyncSummary> {
    const params = providers && providers.length > 0 ? { providers } : {};
    return ipcRequest<SyncSummary>('sync.run', params);
  },

  speedtestRun(): Promise<SpeedResult[]> {
    return ipcRequest<SpeedResult[]>('speedtest.run');
  },

  historyList(n = 20): Promise<HistoryEntry[]> {
    return ipcRequest<HistoryEntry[]>('history.list', { n });
  },

  daemonInstall(): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('daemon.install');
  },

  daemonUninstall(): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('daemon.uninstall');
  },

  daemonStart(): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('daemon.start');
  },

  daemonStop(): Promise<{ ok: boolean }> {
    return ipcRequest<{ ok: boolean }>('daemon.stop');
  },

  daemonStatus(): Promise<DaemonStatus> {
    return ipcRequest<DaemonStatus>('daemon.status');
  },
};
