<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api';
  import type { SpeedResult } from '$lib/ipc-types';

  let running = false;
  let error = '';
  let results: SpeedResult[] = [];

  async function run() {
    running = true;
    error = '';
    results = [];
    try {
      results = await api.speedtestRun();
      results.sort((a, b) => b.speed - a.speed);
    } catch (e) {
      error = String(e);
    } finally {
      running = false;
    }
  }

  onMount(run);
</script>

<h1>测速</h1>
<p class="muted">调用 Go 守护进程的 speedtest.run，返回各 Cloudflare 边缘节点测速结果（按速度降序）。</p>

<div class="row" style="margin:1rem 0">
  <button class="primary" on:click={run} disabled={running}>开始测速</button>
  {#if running}<span class="muted">测速中…</span>{/if}
</div>

{#if error}
  <div class="card" style="border-color:var(--err)">错误：{error}</div>
{/if}

{#if results.length > 0}
  <div class="card">
    <table class="tbl">
      <thead>
        <tr><th>#</th><th>IP</th><th>地区</th><th>延迟(ms)</th><th>丢包(%)</th><th>速度(Mbps)</th><th>收发</th></tr>
      </thead>
      <tbody>
        {#each results as r, i}
          <tr>
            <td class="muted">{i + 1}</td>
            <td>{r.ip}</td>
            <td>{r.colo}</td>
            <td>{r.latency.toFixed(1)}</td>
            <td>{r.loss.toFixed(1)}</td>
            <td>{r.speed.toFixed(1)}</td>
            <td class="muted">{r.sent}/{r.received}</td>
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
