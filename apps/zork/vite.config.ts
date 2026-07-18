import { defineConfig } from "vite";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootDirectory = dirname(fileURLToPath(import.meta.url));

// Vite config for the browser Zork player.
export default defineConfig({
    root: rootDirectory,
    publicDir: "public",
    base: "./",
    build: {
        outDir: "dist",
        emptyOutDir: true,
        sourcemap: true,
    },
    server: {
        port: 5177,
        open: false,
    },
    resolve: {
        alias: {
            "@": resolve(rootDirectory, "src"),
        },
    },
});
