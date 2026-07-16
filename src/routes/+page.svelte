<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api';
  import type { DaemonStatus, HistoryEntry, VersionInfo } from '$lib/ipc-types';

  let version: VersionInfo | null = null;
  let daemon: DaemonStatus | null = null;
  let recent: HistoryEntry[] = [];
  let error = '';
  let loading = true;

  async function load() {
    loading = true;
    error = '';
    try {
      const [v, d, h] = await Promise.all([
        api.version(),
        api.daemonStatus(),
        api.historyList(8),
      ]);
      version = v;
      daemon = d;
      recent = h;
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  onMount(load);

  const stateLabel: Record<string, string> = {
    running: '运行中',
    stopped: '已停止',
    unknown: '未知',
  };
  function fmtTs(ts: string): string {
    const t = new Date(ts);
    return isNaN(t.getTime()) ? ts : t.toLocaleString();
  }
</script>

<h1>概览</h1>
{#if error}
  <div class="card" style="border-color:var(--err)">加载失败：{error}</div>
{/if}
{#if loading}
  <p class="muted">加载中…</p>
{:else}
  <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(220px,1fr))">
    <div class="card">
      <div class="muted">版本</div>
      <div style="font-size:1.1rem">{version?.version ?? '-'}</div>
      <div class="muted" style="font-size:0.75rem">{version?.commit ?? ''}</div>
    </div>
    <div class="card">
      <div class="muted">守护进程</div>
      <div style="font-size:1.1rem">{daemon ? stateLabel[daemon.state] ?? daemon.state : '-'}</div>
    </div>
    <div class="card">
      <div class="muted">最近记录</div>
      <div style="font-size:1.1rem">{recent.length} 条</div>
    </div>
  </div>

  <div class="row" style="margin-top:1.2rem">
    <a href="/sync"><button class="primary">前往一键同步</button></a>
    <a href="/config"><button>配置</button></a>
    <button on:click={load}>刷新</button>
  </div>

  <h3>最近历史</h3>
  {#if recent.length === 0}
    <p class="muted">暂无记录</p>
  {:else}
    <table class="tbl">
      <thead>
        <tr><th>时间</th><th>动作</th><th>摘要</th><th>状态</th></tr>
      </thead>
      <tbody>
        {#each recent as h}
          <tr>
            <td class="muted">{fmtTs(h.ts)}</td>
            <td>{h.action}</td>
            <td class="muted">{h.detail}</td>
            <td style="color:{h.success ? 'var(--ok)' : 'var(--err)'}">{h.success ? '成功' : '失败'}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
{/if}

<style>
  .tbl {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.88rem;
  }
  .tbl th,
  .tbl td {
    text-align: left;
    padding: 0.5rem 0.6rem;
    border-bottom: 1px solid var(--border);
  }
  .tbl th {
    color: var(--muted);
    font-weight: 600;
  }
</style>
