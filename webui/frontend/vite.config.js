import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    host: '0.0.0.0',
    port: 3000,
    proxy: {
      '/api': {
        target: process.env.VITE_API_URL || 'http://kindler-webui-backend:8000',
        changeOrigin: true
      },
      '/ws': {
        target: process.env.VITE_WS_URL || 'ws://kindler-webui-backend:8000',
        ws: true
      }
    }
  }
})

