import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    // 静态单页产物（desktop 用，无服务端渲染）。
    adapter: adapter({
      pages: 'build',
      assets: 'build',
      fallback: 'index.html',
      precompress: false,
    }),
    files: {
      // 本项目 SvelteKit 根即仓库 src/，故 srcDir 设为 '.'，
      // 使 app.html / lib / routes 直接位于 src/ 下（与交付目录结构一致）。
      srcDir: '.',
    },
  },
};

export default config;
