import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  // Bakes the PHOTOSPHERE_THEME env override into the build (read by user-interface env-theme.ts).
  define: { '__PHOTOSPHERE_THEME__': JSON.stringify(process.env.PHOTOSPHERE_THEME || '') },
  server: {
    open: true,
    port: 8080,
  },
  build: {
    sourcemap: true,
    outDir: 'dist',
  },
  publicDir: 'public',
});