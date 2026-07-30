//
// Bundles the embedded worker (`worker.bundle.js`) for the mobile JS engine using Bun's bundler.
//
// The target is the bare embedded engine (QuickJS on Android, JavaScriptCore on iOS), which has no
// Node runtime. Node built-in imports are redirected to the mobile shims in `src/shims` (fs backed by
// the native host bridge; pure-JS path/os/stream/crypto), and the native-only packages the
// load-assets module graph imports (`vault`, `tools`) are redirected to their mobile shims. The AWS
// SDK is NOT redirected: the real, vendor-maintained package is bundled and runs on those shims.
// These redirects must apply to imports made deep inside the other workspace packages
// (node-api/node-utils/storage/vault), so they run as a Bun `onResolve` plugin over the whole graph
// (a package.json `browser` field or tsconfig `paths` only affect the owning package's own files).
//
// Run with: bun scripts/bundle.ts  (wired as the `build:bundle` script).
//

import { dirname, join } from "node:path";

//
// The mobile-worker package root, one level above this script's own `scripts/` directory. Every path
// below (the shims, the entry point, the bundle output) is resolved against it.
//
const packageDir = join(import.meta.dir, "..");

//
// Maps a module specifier to the shim file (relative to this script) it should resolve to. Node
// built-ins are listed without the `node:` prefix; the resolver strips that prefix before looking up
// the map, so both `fs` and `node:fs` resolve to the same shim.
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
    "dgram": "src/shims/node-dgram.ts",
    "tls": "src/shims/node-tls.ts",
    "https": "src/shims/node-https.ts",
    "vault": "src/shims/vault.ts",
    "tools": "src/shims/mobile-tools.ts",
};

//
// The node_modules directories whose internal imports must resolve to the vendor's node variants
// rather than its browser variants: the AWS SDK and the Smithy runtime it is built on.
//
const VENDOR_NODE_VARIANT_PACKAGES = [
    "/node_modules/@aws-sdk/",
    "/node_modules/@smithy/",
];

//
// The few modules inside those packages that are better off as their browser variant, because the
// vendor's browser implementation is pure JavaScript while its node one reaches for a Node built-in
// the engine does not have. Matched against the end of the import specifier.
//
// `getCrc32ChecksumAlgorithmFunction` is the case: the node variant calls `zlib.crc32` (a native Node
// function), while the browser variant uses the vendor's own pure-JS `@aws-crypto/crc32`. Taking the
// browser one keeps the checksum in vendor code instead of putting a CRC implementation in this repo.
//
const VENDOR_BROWSER_VARIANT_MODULES = [
    "getCrc32ChecksumAlgorithmFunction",
];

//
// A Bun bundler plugin that redirects the aliased specifiers to their shim files. It matches the
// exact specifier (after stripping a leading `node:`), so unrelated imports resolve normally.
//
const aliasPlugin: import("bun").BunPlugin = {
    name: "mobile-worker-aliases",
    setup(build) {
        // Match the aliased bare specifiers (with or without a node: prefix). Anchored so only exact
        // module names match, never a deep import that merely starts with one of these names.
        const filter = /^(node:)?(fs\/promises|fs|path|os|stream\/promises|stream|crypto|child_process|zlib|util|http|net|dgram|tls|https|vault|tools)$/;
        build.onResolve({ filter }, args => {
            const specifier = args.path.replace(/^node:/, "");
            const target = aliasMap[specifier];
            if (!target) {
                return undefined;
            }

            return { path: join(packageDir, target) };
        });

        // The bundle targets "browser" so Bun supplies polyfills for the Node built-ins the shims do
        // not cover. That target also makes Bun honour the `browser` field in the AWS SDK's
        // package.json files, which swaps in variants written for a DOM: `fetch`, `ReadableStream`,
        // `TextEncoder`, `btoa`. The engine has none of those; what it has is the Node-shaped shims
        // above. So resolve the SDK's own internal imports the way Node would, which selects the node
        // variants the vendor already ships and lands them on those shims. This only chooses between
        // files the vendor supplies; nothing here reimplements any part of the SDK.
        build.onResolve({ filter: /^\.\.?\// }, args => {
            if (!VENDOR_NODE_VARIANT_PACKAGES.some(vendorDir => args.importer.includes(vendorDir))) {
                return undefined;
            }

            if (VENDOR_BROWSER_VARIANT_MODULES.some(moduleName => args.path.endsWith(moduleName))) {
                return undefined;
            }

            return { path: Bun.resolveSync(args.path, dirname(args.importer)) };
        });
    },
};

//
// Runs the bundle build and writes worker.bundle.js, failing the process on any build error.
//
async function main(): Promise<void> {
    const result = await Bun.build({
        entrypoints: [join(packageDir, "mobile-worker-entry.ts")],
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
    await Bun.write(join(packageDir, "worker.bundle.js"), code);
    console.log(`Built worker.bundle.js (${code.length} bytes)`);
}

await main();
