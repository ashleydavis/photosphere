import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  base: './', // Capacitor serves from a non-http origin, so relative asset paths are required.
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
  },
});
