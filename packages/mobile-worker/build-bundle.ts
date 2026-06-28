//
// Builds the embedded worker bundle (`worker.bundle.js`) for the mobile JS engine.
//
// The bundle target is the bare embedded engine (QuickJS on Android, JavaScriptCore on iOS), which
// has no Node runtime. So this build redirects Node built-in imports to the mobile shims in
// `src/shims` (fs backed by the native host bridge; pure-JS path/os/stream/crypto), and stubs the
// native-only packages the load-assets module graph imports but the read path never calls
// (`@aws-sdk/*`, `vault`, `tools`). The output is a single IIFE that installs
// `globalThis.__photosphereWorker.runTask`.
//
// Run with: bun build-bundle.ts  (wired as the `build:bundle` script).
//

import { join } from "node:path";

//
// The directory containing this build script (packages/mobile-worker).
//
const scriptDir = import.meta.dir;

//
// Maps a module specifier to the shim/stub file (relative to this script) it should resolve to.
// Node built-ins are listed without the `node:` prefix; the resolver strips that prefix before
// looking up the map, so both `fs` and `node:fs` resolve to the same shim.
//
const aliasMap: Record<string, string> = {
    "fs/promises": "src/shims/node-fs-promises.ts",
    "fs": "src/shims/node-fs.ts",
    "path": "src/shims/node-path.ts",
    "os": "src/shims/node-os.ts",
    "stream/promises": "src/shims/node-stream-promises.ts",
    "stream": "src/shims/node-stream.ts",
    "crypto": "src/shims/node-crypto.ts",
    "child_process": "src/shims/node-child_process.ts",
    "zlib": "src/shims/node-zlib.ts",
    "util": "src/shims/node-util.ts",
    "http": "src/shims/node-http.ts",
    "net": "src/shims/node-net.ts",
    "@aws-sdk/client-s3": "src/shims/stub-aws-s3.ts",
    "@aws-sdk/lib-storage": "src/shims/stub-aws-lib-storage.ts",
    "vault": "src/shims/stub-vault.ts",
    "tools": "src/shims/stub-tools.ts",
};

//
// A Bun bundler plugin that redirects the aliased specifiers to their shim/stub files. It matches
// the exact specifier (after stripping a leading `node:`), so unrelated imports resolve normally.
//
const aliasPlugin: import("bun").BunPlugin = {
    name: "mobile-worker-aliases",
    setup(build) {
        // Match the aliased bare specifiers (with or without a node: prefix). Anchored so only exact
        // module names match, never a deep import that merely starts with one of these names.
        const filter = /^(node:)?(fs\/promises|fs|path|os|stream\/promises|stream|crypto|child_process|zlib|util|http|net|@aws-sdk\/client-s3|@aws-sdk\/lib-storage|vault|tools)$/;
        build.onResolve({ filter }, args => {
            const specifier = args.path.replace(/^node:/, "");
            const target = aliasMap[specifier];
            if (!target) {
                return undefined;
            }

            return { path: join(scriptDir, target) };
        });
    },
};

//
// Runs the bundle build and writes worker.bundle.js, failing the process on any build error.
//
async function main(): Promise<void> {
    const result = await Bun.build({
        entrypoints: [join(scriptDir, "mobile-worker-entry.ts")],
        target: "browser",
        format: "iife",
        plugins: [aliasPlugin],
    });

    if (!result.success) {
        for (const message of result.logs) {
            console.error(message);
        }
        throw new Error("Worker bundle build failed.");
    }

    const artifact = result.outputs[0];
    const code = await artifact.text();
    await Bun.write(join(scriptDir, "worker.bundle.js"), code);
    console.log(`Built worker.bundle.js (${code.length} bytes)`);
}

await main();
