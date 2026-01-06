import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  base: './',
  define: {
    'process.env.NODE_ENV': '"development"', // Use development builds for better error messages
  },
  build: {
    sourcemap: true, // Generate separate source map files
    minify: false, // Disable minification for better error messages in Electron
    outDir: '../desktop/bundle/frontend',
    emptyOutDir: true,
    chunkSizeWarningLimit: Infinity, // Disable chunk size warnings
  },
});

