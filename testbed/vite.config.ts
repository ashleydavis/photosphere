import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    open: true,
    port: 3004,
  },
  resolve: {
    alias: {
      'crypto': 'crypto-browserify',
    },
  },
  build: {
    sourcemap: true,
    outDir: 'dist',
  },
});