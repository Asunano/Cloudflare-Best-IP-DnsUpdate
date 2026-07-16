<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api';
  import type { HistoryEntry } from '$lib/ipc-types';

  let items: HistoryEntry[] = [];
  let loading = false;
  let error = '';

  async function load(n = 50) {
    loading = true;
    error = '';
    try {
      items = await api.historyList(n);
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  function fmtTs(ts: string): string {
    const t = new Date(ts);
    return isNaN(t.getTime()) ? ts : t.toLocaleString();
  }

  onMount(() => load());
</script>

<h1>历史</h1>
<p class="muted">调用 daemon.history.list 读取最近的执行记录（测速 / 各模块同步）。</p>

<div class="row" style="margin:1rem 0">
  <button on:click={() => load(50)} disabled={loading}>刷新</button>
  <button on:click={() => load(200)} disabled={loading}>载入更多</button>
</div>

{#if error}
  <div class="card" style="border-color:var(--err)">错误：{error}</div>
{/if}

{#if items.length === 0 && !loading}
  <p class="muted">暂无记录</p>
{:else}
  <div class="card">
    <table class="tbl">
      <thead>
        <tr><th>时间</th><th>动作</th><th>摘要</th><th>状态</th></tr>
      </thead>
      <tbody>
        {#each items as h}
          <tr>
            <td class="muted">{fmtTs(h.ts)}</td>
            <td>{h.action}</td>
            <td class="muted">{h.detail}</td>
            <td style="color:{h.success ? 'var(--ok)' : 'var(--err)'}">{h.success ? '成功' : '失败'}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}

<style>
  .tbl {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.86rem;
  }
  .tbl th,
  .tbl td {
    text-align: left;
    padding: 0.45rem 0.6rem;
    border-bottom: 1px solid var(--border);
  }
  .tbl th {
    color: var(--muted);
    font-weight: 600;
  }
</style>
