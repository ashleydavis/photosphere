import { watch } from 'node:fs';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Whether Linux has a file watch to spare. Other programs can use up every watch the user is allowed, and Vite then
// crashes with ENOSPC instead of watching the frontend.
function canWatchFiles(): boolean {
  try {
    watch('src').close();
    return true;
  }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOSPC') {
      return false;
    }
    throw error;
  }
}

const useWatchPolling = !canWatchFiles();
if (useWatchPolling) {
  console.warn('No file watches left on this machine, so Vite checks the frontend for changes by polling.');
}

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    watch: {
      usePolling: useWatchPolling,
    },
  },
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
