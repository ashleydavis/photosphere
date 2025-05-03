import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    open: true,
    port: 8080,
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