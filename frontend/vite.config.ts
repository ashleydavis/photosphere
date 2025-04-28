import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    open: true,
    port: 3001,
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
  publicDir: 'public',
});