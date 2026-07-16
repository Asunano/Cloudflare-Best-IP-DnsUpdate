<script lang="ts">
  import '../app.css';
  import { page } from '$app/stores';
</script>

<div class="shell">
  <aside class="sidebar">
    <div class="brand">
      <div class="logo">cfopt</div>
      <div class="muted" style="font-size:0.72rem">Cloudflare 优选 & DNS 同步</div>
    </div>
    <nav>
      <a href="/" class:active={$page.url.pathname === '/'}>概览</a>
      <a href="/sync" class:active={$page.url.pathname.startsWith('/sync')}>一键同步</a>
      <a href="/speedtest" class:active={$page.url.pathname.startsWith('/speedtest')}>测速</a>
      <a href="/config" class:active={$page.url.pathname.startsWith('/config')}>配置</a>
      <a href="/history" class:active={$page.url.pathname.startsWith('/history')}>历史</a>
      <a href="/daemon" class:active={$page.url.pathname.startsWith('/daemon')}>守护进程</a>
    </nav>
  </aside>
  <main>
    <slot />
  </main>
</div>

<style>
  .shell {
    display: grid;
    grid-template-columns: 220px 1fr;
    height: 100vh;
  }
  .sidebar {
    background: var(--panel);
    border-right: 1px solid var(--border);
    padding: 1rem 0.8rem;
    display: flex;
    flex-direction: column;
    gap: 1.2rem;
  }
  .brand .logo {
    font-size: 1.3rem;
    font-weight: 700;
    letter-spacing: 0.5px;
  }
  nav {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
  }
  nav a {
    color: var(--text);
    padding: 0.5rem 0.6rem;
    border-radius: 6px;
    font-size: 0.92rem;
  }
  nav a:hover {
    background: var(--panel-2);
  }
  nav a.active {
    background: var(--panel-2);
    border-left: 3px solid var(--accent);
    color: #fff;
  }
  main {
    padding: 1.4rem 1.8rem;
    overflow: auto;
  }
</style>
