import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import electron from 'vite-plugin-electron-renderer';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    electron()
  ],
  server: {
    port: 8080,
  },
  build: {
    sourcemap: true,
    outDir: 'dist',
  },
  // Configure for Electron renderer
  base: './',
});