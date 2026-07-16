import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  // Tauri 期望固定端口以便 beforeDevCommand 复用。
  clearScreen: false,
  server: {
    port: 5173,
    strictPort: true,
    host: false,
  },
});
