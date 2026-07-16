<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { api } from '$lib/api';
  import { onProgress } from '$lib/tauri';
  import { progressEvents, syncing, lastSummary, resetProgress } from '$lib/stores';
  import type { ProgressEvent, SyncSummary } from '$lib/ipc-types';

  let running = false;
  let error = '';
  let unlisten: (() => void) | null = null;

  // 可选 providers 过滤（仅同步指定且启用的模块）。
  let providerInput = '';

  onMount(async () => {
    resetProgress();
    unlisten = await onProgress((e: ProgressEvent) => {
      progressEvents.update((arr) => [...arr, e]);
    });
  });
  onDestroy(() => unlisten?.());

  async function run() {
    running = true;
    error = '';
    syncing.set(true);
    resetProgress();
    const providers = providerInput
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    try {
      const summary: SyncSummary = await api.syncRun(providers.length ? providers : undefined);
      lastSummary.set(summary);
    } catch (e) {
      error = String(e);
    } finally {
      running = false;
      syncing.set(false);
    }
  }

  $: events = $progressEvents;
  $: summary = $lastSummary;
  $: last = events[events.length - 1];
  $: pct = last && last.total > 0 ? Math.round((last.cur / last.total) * 100) : 0;
</script>

<h1>一键同步</h1>
<p class="muted">
  流程：测速 → 提取最优 IP → 写入各模块 IP 源文件 → 遍历启用模块同步 DNS。进度实时刷新。
</p>

<div class="card">
  <label for="providers">仅同步指定模块（可选，逗号分隔，如 cloudflare,dnspod；留空=全部启用）</label>
  <input id="providers" bind:value={providerInput} placeholder="cloudflare,dnspod" disabled={running} />
  <div class="row" style="margin-top:0.8rem">
    <button class="primary" on:click={run} disabled={running}>开始同步</button>
    {#if running}<span class="muted">同步中…</span>{/if}
  </div>
</div>

{#if error}
  <div class="card" style="border-color:var(--err);margin-top:1rem">错误：{error}</div>
{/if}

{#if events.length > 0}
  <div class="card" style="margin-top:1rem">
    <div class="row" style="justify-content:space-between">
      <strong>进度</strong>
      <span class="muted">{last ? `${last.cur}/${last.total}` : ''} · {pct}%</span>
    </div>
    <div class="bar"><div class="fill" style="width:{pct}%"></div></div>
    <ul class="log">
      {#each events as e}
        <li>
          <span class="phase">{e.phase}</span>
          <span class="muted">{e.message || ''}</span>
          <span class="muted">({e.cur}/{e.total})</span>
        </li>
      {/each}
    </ul>
  </div>
{/if}

{#if summary}
  <div class="card" style="margin-top:1rem">
    <h3>执行结果</h3>
    <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(120px,1fr))">
      <div><div class="muted">最优 IP</div><div style="font-size:1.2rem">{summary.best_ip_count}</div></div>
      <div><div class="muted">更新</div><div style="font-size:1.2rem">{summary.updated}</div></div>
      <div><div class="muted">新建</div><div style="font-size:1.2rem">{summary.created}</div></div>
      <div><div class="muted">删除</div><div style="font-size:1.2rem">{summary.deleted}</div></div>
    </div>
    {#if summary.errors.length}
      <ul style="color:var(--err)">
        {#each summary.errors as err}<li>{err}</li>{/each}
      </ul>
    {/if}
  </div>
{/if}

<style>
  .bar {
    height: 8px;
    background: var(--panel-2);
    border-radius: 6px;
    overflow: hidden;
    margin: 0.5rem 0;
  }
  .fill {
    height: 100%;
    background: var(--accent);
    transition: width 0.2s ease;
  }
  .log {
    list-style: none;
    padding: 0;
    margin: 0.4rem 0 0;
    max-height: 200px;
    overflow: auto;
    font-size: 0.84rem;
  }
  .log li {
    padding: 0.2rem 0;
    border-bottom: 1px solid var(--border);
    display: flex;
    gap: 0.5rem;
  }
  .phase {
    font-weight: 600;
    min-width: 90px;
  }
</style>
