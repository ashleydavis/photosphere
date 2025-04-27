import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 3003,
  },
  build: {
    sourcemap: true,
    outDir: 'dist',
  },
  // Configure for Electron renderer
  base: './',
});