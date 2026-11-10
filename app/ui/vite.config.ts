import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'
import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'

const backend = 'http://127.0.0.1:9000'

export default defineConfig({
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: true,
    proxy: { '/webui.js': backend },
  },
  build: {
    outDir: 'dist',
    target: 'es2023',
    chunkSizeWarningLimit: 2000,
  },
  plugins: [react(), babel({ presets: [reactCompilerPreset()] }), tailwindcss()],
})
