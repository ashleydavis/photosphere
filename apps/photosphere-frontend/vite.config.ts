import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  base: './',
  define: {
    // Bakes the PHOTOSPHERE_THEME env override into the build (read by user-interface env-theme.ts).
    '__PHOTOSPHERE_THEME__': JSON.stringify(process.env.PHOTOSPHERE_THEME || ''),
  },
  build: {
    sourcemap: false, // The page is embedded in the app, so there is nowhere to serve a source map from
    minify: false, // Disable minification for better error messages
    outDir: 'dist',
    emptyOutDir: true,
    chunkSizeWarningLimit: Infinity, // Disable chunk size warnings
  },
});
