<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api';
  import type { Config } from '$lib/ipc-types';

  let cfg: Config = {};
  let loading = false;
  let saving = false;
  let validating = false;
  let error = '';
  let message = '';

  // 确保嵌套对象存在，便于 bind:value 绑定。
  function ensureShape(c: Config): Config {
    c.global ??= {};
    c.cf_ip ??= {};
    c.cf_ip.cfst ??= {};
    c.cf_ip.speed_test ??= {};
    c.cf_ip.paths ??= {};
    c.cf_dns ??= {};
    c.cf_dns.api ??= {};
    c.cf_dns.dns ??= {};
    c.dnspod ??= {};
    return c;
  }

  async function load() {
    loading = true;
    error = '';
    try {
      cfg = ensureShape(await api.configGet());
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  async function validate() {
    validating = true;
    error = '';
    message = '';
    try {
      const r = await api.configValidate(cfg);
      message = r.ok ? '配置校验通过' : '配置校验未通过';
    } catch (e) {
      error = String(e);
    } finally {
      validating = false;
    }
  }

  async function save() {
    saving = true;
    error = '';
    message = '';
    try {
      const r = await api.configSave(cfg);
      message = r.ok ? '配置已保存' : '保存失败';
    } catch (e) {
      error = String(e);
    } finally {
      saving = false;
    }
  }

  onMount(load);
</script>

<h1>配置</h1>
{#if error}
  <div class="card" style="border-color:var(--err)">错误：{error}</div>
{/if}
{#if message}
  <div class="card" style="border-color:var(--ok)">{message}</div>
{/if}

{#if loading}
  <p class="muted">加载中…</p>
{:else}
  <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(280px,1fr))">

    <div class="card">
      <h3>Cloudflare IP 优选</h3>
      <label><input type="checkbox" bind:checked={cfg.cf_ip.enabled} /> 启用</label>
      <label>测速输出目录</label>
      <input bind:value={cfg.cf_ip.paths.output_dir} placeholder="assets/data" />
      <label>cfst 目录</label>
      <input bind:value={cfg.cf_ip.cfst.directory} placeholder="assets/cfst" />
      <label>cfst 二进制名</label>
      <input bind:value={cfg.cf_ip.cfst.binary} placeholder="cfst" />
      <label>线程数</label>
      <input type="number" bind:value={cfg.cf_ip.cfst.threads} />
      <label>地区过滤 (逗号分隔)</label>
      <input bind:value={cfg.cf_ip.cfst.colo} placeholder="HKG,NRT" />
      <label>取最优 IP 数量</label>
      <input type="number" bind:value={cfg.cf_ip.speed_test.take_ip_num} />
    </div>

    <div class="card">
      <h3>Cloudflare DNS</h3>
      <label><input type="checkbox" bind:checked={cfg.cf_dns.enabled} /> 启用</label>
      <label>API Token</label>
      <input type="password" bind:value={cfg.cf_dns.api.token} />
      <label>Zone ID</label>
      <input bind:value={cfg.cf_dns.api.zone_id} />
      <label>记录名 (子域名 / @)</label>
      <input bind:value={cfg.cf_dns.dns.record_name} />
      <label>域名</label>
      <input bind:value={cfg.cf_dns.dns.domain} />
      <label>每记录最大 IP 数</label>
      <input type="number" bind:value={cfg.cf_dns.dns.max_ips_per_record} />
    </div>

    <div class="card">
      <h3>DNSPod</h3>
      <label><input type="checkbox" bind:checked={cfg.dnspod.enabled} /> 启用</label>
      <label>Secret ID</label>
      <input bind:value={cfg.dnspod.secret_id} />
      <label>Secret Key</label>
      <input type="password" bind:value={cfg.dnspod.secret_key} />
      <label>模式</label>
      <select bind:value={cfg.dnspod.mode}>
        <option value="single">single（单线路）</option>
        <option value="isp_lines">isp_lines（多运营商分流）</option>
      </select>
      <label>域名</label>
      <input bind:value={cfg.dnspod.domain} />
      <label>子域名</label>
      <input bind:value={cfg.dnspod.sub_domain} />
      <label>TTL</label>
      <input type="number" bind:value={cfg.dnspod.ttl} />
    </div>

  </div>

  <div class="row" style="margin-top:1rem">
    <button class="primary" on:click={save} disabled={saving}>保存</button>
    <button on:click={validate} disabled={validating}>校验</button>
    <button on:click={load}>重新加载</button>
  </div>
{/if}
