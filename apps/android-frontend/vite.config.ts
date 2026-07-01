import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  base: './', // Capacitor serves from a non-http origin, so relative asset paths are required.
  // Bakes the PHOTOSPHERE_THEME env override into the build (read by user-interface env-theme.ts).
  define: { '__PHOTOSPHERE_THEME__': JSON.stringify(process.env.PHOTOSPHERE_THEME || '') },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
  },
});
