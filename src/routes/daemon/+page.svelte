<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api';
  import type { DaemonStatus } from '$lib/ipc-types';

  let status: DaemonStatus | null = null;
  let loading = false;
  let error = '';

  async function refresh() {
    loading = true;
    error = '';
    try {
      status = await api.daemonStatus();
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  async function act(fn: () => Promise<{ ok: boolean }>, label: string) {
    error = '';
    try {
      const r = await fn();
      if (!r.ok) error = `${label} 返回失败`;
    } catch (e) {
      error = String(e);
    }
    await refresh();
  }

  onMount(refresh);

  const stateLabel: Record<string, string> = {
    running: '运行中',
    stopped: '已停止',
    unknown: '未知',
  };
</script>

<h1>守护进程</h1>
<p class="muted">
  常驻调度守护进程（系统服务：install/uninstall + start/stop）。
  注意：本 GUI 的即时调用通过临时拉起的 Go sidecar（IPC）完成，与系统调度守护进程相互独立。
</p>

{#if error}
  <div class="card" style="border-color:var(--err)">错误：{error}</div>
{/if}

<div class="card">
  <div class="row" style="justify-content:space-between">
    <div>
      <div class="muted">当前状态</div>
      <div style="font-size:1.1rem">{status ? stateLabel[status.state] ?? status.state : '加载中…'}</div>
    </div>
    <button on:click={refresh} disabled={loading}>刷新</button>
  </div>
</div>

<div class="card" style="margin-top:1rem">
  <h3>服务管理</h3>
  <div class="row">
    <button on:click={() => act(api.daemonInstall, '安装')}>安装服务</button>
    <button on:click={() => act(api.daemonUninstall, '卸载')}>卸载服务</button>
    <button class="primary" on:click={() => act(api.daemonStart, '启动')}>启动</button>
    <button on:click={() => act(api.daemonStop, '停止')}>停止</button>
  </div>
</div>
