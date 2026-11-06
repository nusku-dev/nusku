import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'
import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'

// Must match `dev_port` in ../build.zig: the backend's port in `zig build run -Ddev`.
const backend = 'http://127.0.0.1:9000'

export default defineConfig({
  server: {
    host: '127.0.0.1',
    port: 5173, // must match `vite_url` in ../src/main.zig
    strictPort: true,
    // The page comes from Vite, the bridge from the backend. The bridge then opens its
    // WebSocket straight to the backend's port.
    proxy: { '/webui.js': backend },
  },
  build: {
    // `zig build` passes --outDir (a directory in the Zig cache) and embeds the result.
    outDir: 'dist',
    target: 'es2023',
  },
  plugins: [react(), babel({ presets: [reactCompilerPreset()] }), tailwindcss(),],
})
