# Pluggable AI Integration

Companion to [ai-implementation-priorities.md](ai-implementation-priorities.md) and [ai-integration-options.md](ai-integration-options.md). Those docs decide *what* to build. This one describes the *shape* the AI integration should take so individual features stay loosely coupled, easy to add, and easy to remove.

The architecture has two halves:
- **Code is compile-time pluggable**. Every AI feature is a self-contained plugin module behind a small interface. The set of active plugins is a single registry file. All plugin code is bundled into the Bun single-exe CLI and the Electron installer; there is no dynamic loading from disk at runtime.
- **Models are runtime pluggable**. Each plugin declares its model assets in a manifest. Photosphere downloads the assets from a dedicated GitHub releases repository on first use, verifies SHA-256, and caches them in the user data dir.

---

## Goals

- Adding a new AI feature touches one new plugin file and one line in a registry. Nothing else.
- Removing a feature is the reverse: delete one file, delete one line. Compiler tells you if anything still depends on it.
- Features call capabilities ("give me an image embedder") instead of importing concrete model implementations. Swapping SigLIP 2 for OpenCLIP is a registry edit, not a feature rewrite.
- Model weights ship out-of-band via GitHub releases, are downloaded on first use, and never bloat the CLI exe.
- Same code path on CLI and Electron. Same cache directory shared between them.

## Non-goals

- Loading plugins from disk at runtime. No `.so` / `.dll` / `.js` plugin files. The single-exe constraint makes this impossible without unpacking, and there is no value in supporting it.
- A third-party plugin marketplace. All plugins are in-tree.
- Hot-reload of plugins. Restart the process.
- Per-collection plugin config. Plugins are global; per-collection enable/disable can come later if anyone asks.

---

## Architecture at a glance

```
+-----------------+   +-----------------+   +-----------------+
| Feature:        |   | Feature: face   |   | Feature:        |
| semantic search |   | recognition     |   | captioning      |
+--------+--------+   +--------+--------+   +--------+--------+
         |                     |                     |
         | getCapability(...)  |                     |
         v                     v                     v
+----------------------------------------------------------------+
|                     AiPluginRegistry                            |
|       (capability lookup, enable/disable, lifecycle)            |
+----------------------------------------------------------------+
         |                     |                     |
         v                     v                     v
+----------------+    +----------------+    +----------------+
| SigLIP 2       |    | SCRFD +        |    | Florence-2     |
| plugin         |    | Buffalo plugin |    | plugin         |
+--------+-------+    +--------+-------+    +--------+-------+
         |                     |                     |
         | resources.ensure()  |                     |
         v                     v                     v
+----------------------------------------------------------------+
|                      IResourceManager                           |
|         (download + SHA-256 verify + on-disk cache)             |
+----------------------------------------------------------------+
                              |
                              v
                  GitHub releases (model assets)
```

---

## The plugin interface

A new shared workspace `packages/ai` owns the contracts. Every plugin lives in `packages/ai/src/plugins/<plugin-id>/`.

```typescript
// packages/ai/src/types.ts

// Discrete kind of work an AI plugin can perform. Features look up plugins by capability
// rather than by name, so swapping the underlying model is a one-line registry change.
export type AiCapability =
    | "image-embedding"
    | "text-embedding"
    | "face-detection"
    | "face-embedding"
    | "caption-generation"
    | "tag-generation"
    | "reverse-geocoding";

// Pointer to a single GitHub release asset. Used to locate large model files that cannot
// be bundled into the CLI exe or Electron installer.
export interface IGithubReleaseRef {
    // GitHub owner (user or org).
    owner: string;
    // Repository name. Conventionally a dedicated assets repo, e.g. "photosphere-ai-models".
    repo: string;
    // Release tag, pinned. Never "latest". Bumping a model is a new tag, not an in-place upload.
    tag: string;
    // Asset filename uploaded to the release.
    asset: string;
}

// A model file or dataset that a plugin needs at runtime.
export interface IPluginResource {
    // Stable identifier used as the on-disk cache key. Kebab-case, includes a version suffix.
    id: string;
    // Expected size in bytes. Used for the download progress UI and as a sanity check.
    sizeBytes: number;
    // SHA-256 of the asset, hex-encoded. Verified after download; mismatch aborts and retries.
    sha256: string;
    // Where to fetch the asset from.
    githubRelease: IGithubReleaseRef;
}

// Runtime services handed to a plugin during init. Hides the difference between CLI and
// Electron hosts so plugin code never has to ask which one it is in.
export interface IPluginContext {
    // Resolves a declared resource to a local file path, downloading on first use.
    resources: IResourceManager;
    // Append-only log surface for plugin progress messages.
    log: ILogger;
    // Cancellation signal. Honour during long-running init and inference.
    abortSignal: AbortSignal;
}

// Loads, caches, and verifies plugin resources.
export interface IResourceManager {
    // Returns the absolute local path for the resource. Downloads from GitHub on first use.
    // Verifies SHA-256 before returning. Throws on hash mismatch or download failure.
    ensure(resource: IPluginResource): Promise<string>;
    // Returns the cached path without downloading. Returns undefined if not yet cached.
    locate(resourceId: string): string | undefined;
}

// Plugin instance contract. Each AI module implements this once.
export interface IAiPlugin {
    // Unique identifier, kebab-case.
    readonly id: string;
    // Human-readable name shown in the Electron settings UI.
    readonly name: string;
    // Capabilities provided by this plugin.
    readonly capabilities: AiCapability[];
    // Resources the plugin must download before first use.
    readonly resources: IPluginResource[];
    // Initialise the plugin. Load models, allocate buffers.
    init(context: IPluginContext): Promise<void>;
    // Dispose of loaded resources.
    dispose(): Promise<void>;
}
```

Capability-specific interfaces live next to the base types. A plugin implements `IAiPlugin` plus one or more capability interfaces.

```typescript
// packages/ai/src/capabilities.ts

// Encodes an image into a fixed-size embedding vector, normalized.
export interface IImageEmbedder {
    // Encode raw image bytes to a unit-length embedding vector.
    embedImage(imageBytes: Uint8Array): Promise<Float32Array>;
}

// Encodes a text query into the same embedding space as IImageEmbedder.
export interface ITextEmbedder {
    // Encode a text query to a unit-length embedding vector.
    embedText(query: string): Promise<Float32Array>;
}

// Detects face bounding boxes in an image.
export interface IFaceDetector {
    // Return one bounding box per face detected in the image.
    detectFaces(imageBytes: Uint8Array): Promise<IFaceBox[]>;
}

// Bounding box for one detected face.
export interface IFaceBox {
    // Horizontal pixel offset of the top-left corner.
    x: number;
    // Vertical pixel offset of the top-left corner.
    y: number;
    // Width of the box in pixels.
    width: number;
    // Height of the box in pixels.
    height: number;
    // Detector confidence in [0, 1].
    confidence: number;
}
```

---

## The capability registry

A single file lists every plugin compiled into the build. Adding a plugin is one new import and one new array entry. Removing is the reverse.

```typescript
// packages/ai/src/registry.ts

import { SiglipImageEmbedderPlugin } from "./plugins/siglip-image-embedder";
import { SiglipTextEmbedderPlugin } from "./plugins/siglip-text-embedder";
import { ScrfdFaceDetectorPlugin } from "./plugins/scrfd-face-detector";
import { BuffaloFaceEmbedderPlugin } from "./plugins/buffalo-face-embedder";
import { Florence2CaptionPlugin } from "./plugins/florence2-caption";
import { GeonamesGeocoderPlugin } from "./plugins/geonames-geocoder";

// Every plugin compiled into the build. Order matters: when multiple plugins provide the
// same capability, the first enabled one wins. User settings can flip the active choice.
export const allPlugins: IAiPluginConstructor[] = [
    SiglipImageEmbedderPlugin,
    SiglipTextEmbedderPlugin,
    ScrfdFaceDetectorPlugin,
    BuffaloFaceEmbedderPlugin,
    Florence2CaptionPlugin,
    GeonamesGeocoderPlugin,
];
```

The registry itself indexes plugins by capability and handles enable/disable:

```typescript
// packages/ai/src/plugin-registry.ts

// Indexes plugins by capability and exposes capability lookups to feature code.
export class AiPluginRegistry {
    // All instantiated plugins.
    private plugins: IAiPlugin[];
    // Capability index: capability name -> ordered list of plugins providing it.
    private byCapability: Map<AiCapability, IAiPlugin[]>;
    // Disabled plugin ids, persisted in user settings.
    private disabled: Set<string>;

    // Initialise every plugin. Resources are downloaded lazily on first capability use,
    // not here, so first launch stays fast.
    async init(context: IPluginContext): Promise<void> { /* ... */ }

    // Look up the active plugin for a capability. Returns undefined if none is enabled.
    getCapability<TCapability>(capability: AiCapability): TCapability | undefined { /* ... */ }

    // Disable a plugin by id. Persisted to user settings.
    disable(pluginId: string): void { /* ... */ }

    // Re-enable a previously disabled plugin.
    enable(pluginId: string): void { /* ... */ }
}
```

Feature code never imports plugins directly. It asks for capabilities:

```typescript
// Inside the semantic search feature.
const imageEmbedder = pluginRegistry.getCapability<IImageEmbedder>("image-embedding");
if (!imageEmbedder) {
    throw new Error("No image embedding plugin is enabled");
}
const embedding = await imageEmbedder.embedImage(photoBytes);
```

This is how swapping models stays cheap: register a different plugin under the same capability and every feature picks up the change.

---

## Model resources via GitHub releases

A dedicated assets repository (suggested name `photosphere-ai-models`) hosts model files as GitHub release assets.

**Repo layout**:
- One repository, many releases.
- One release per model version. Tag format: `<plugin-id>-<model-version>`. Examples: `siglip2-base-v1.0`, `scrfd-10g-v1.0`, `florence2-base-v1.0`.
- Tags are immutable. A new model version is a new release with a new tag, never an in-place asset replacement.

**Why GitHub releases (not LFS, not S3, not Hugging Face)**:
- Public release downloads do not consume GitHub API rate limits because the download is a redirect to GitHub's object storage. Unauthenticated downloads scale.
- Asset URLs are stable and predictable: `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`.
- Versioning, release notes, and asset hosting live in one place.
- No infrastructure to run, no third-party account, no bills.

**Asset conventions**:
- One asset per resource. Do not bundle multiple files into a tarball: the resource manager handles one file at a time and partial caches must be possible.
- Provide a sibling `<asset>.sha256` file in the same release for human verification. Photosphere does not read it; it carries its own copy of the hash compiled in.
- Keep individual assets under 2GB (GitHub's per-asset limit). Split larger models across multiple resources if needed.

**Manifest in code**:
Each plugin declares its resources statically:

```typescript
// packages/ai/src/plugins/siglip-image-embedder/index.ts

const SIGLIP2_MODEL_RESOURCE: IPluginResource = {
    id: "siglip2-base-v1.0",
    sizeBytes: 419_430_400,
    sha256: "a1b2c3...e4f5",
    githubRelease: {
        owner: "ashleydavis",
        repo: "photosphere-ai-models",
        tag: "siglip2-base-v1.0",
        asset: "siglip2-base.onnx",
    },
};

export class SiglipImageEmbedderPlugin implements IAiPlugin, IImageEmbedder {
    readonly id = "siglip-image-embedder";
    readonly name = "SigLIP 2 image embedding";
    readonly capabilities: AiCapability[] = ["image-embedding"];
    readonly resources: IPluginResource[] = [SIGLIP2_MODEL_RESOURCE];

    // ...
}
```

Hashes are part of the source tree. Bumping a model version is a code change that updates the resource id, tag, and SHA together. This makes downgrades and audits trivial.

---

## Download and cache lifecycle

`IResourceManager` is responsible for turning a `IPluginResource` into a local file path. It lives in `packages/ai/src/resource-manager.ts`.

**Cache location**:
- Linux: `$XDG_DATA_HOME/photosphere/models/<resource-id>/<sha256-prefix>/<asset>`
- macOS: `~/Library/Application Support/photosphere/models/<resource-id>/<sha256-prefix>/<asset>`
- Windows: `%APPDATA%\photosphere\models\<resource-id>\<sha256-prefix>\<asset>`

The CLI and Electron share the same cache directory. Multiple Photosphere installs on the same machine share weights.

**Cache key**:
`<resource-id>/<sha256-prefix>`. Including the hash prefix lets old model versions coexist with new ones for the duration of an upgrade. Cleanup is a separate pass.

**Download algorithm**:
1. If the path exists and its SHA-256 matches, return it.
2. Otherwise, fetch `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` to a temp file in the same directory.
3. Stream-hash while downloading. Compare against the expected SHA-256.
4. On match, atomically rename the temp file into place. Return the path.
5. On mismatch or network error, delete the temp file, exponential-backoff retry (max 3 attempts), then surface the error to the caller.

**Progress reporting**:
The download is exposed as a Photosphere background task using the existing background-tasks system (see `docs/background-tasks.md`). The Electron UI shows it as "Downloading model: SigLIP 2 (200MB of 400MB)" with cancel.

**First-launch behaviour**:
Plugin `init()` does *not* download resources. Resources are downloaded lazily on first capability use, so launching Photosphere does not require a network. The first time a feature calls `getCapability("image-embedding")` and invokes a method that needs the model, the resource manager downloads it.

**Offline behaviour**:
If a resource is not cached and the network is unavailable, the capability call throws a typed error (`ResourceUnavailableError`) that features handle by disabling themselves in the UI. The user can pre-stage models manually by copying files into the cache directory; the resource manager verifies the SHA and accepts pre-staged files.

**Side-loading (air-gapped machines)**:
Users on air-gapped machines can download the GitHub release assets on a connected machine and copy them into the cache directory. The resource manager treats them identically to its own downloads.

---

## Adding a new plugin (worked example)

Suppose we want to add an OpenCLIP plugin as an alternative image embedder.

1. Create `packages/ai/src/plugins/openclip-image-embedder/index.ts`. Implement `IAiPlugin` and `IImageEmbedder`. Declare the OpenCLIP ONNX resource.
2. Upload the ONNX file to a new GitHub release in `photosphere-ai-models` tagged `openclip-vitb32-v1.0`. Compute the SHA-256, paste it into the resource declaration.
3. Add the import and the array entry to `packages/ai/src/registry.ts`.
4. Add a unit test that instantiates the plugin and verifies it implements `IImageEmbedder` (uses a stub `IPluginContext` that pretends the model is already cached).
5. Done. Existing semantic search feature picks it up automatically when the user selects it in the Electron settings (or if it is the only enabled `image-embedding` plugin).

Total surface area touched: one new directory, one line in the registry, one unit test.

---

## Removing a plugin

1. Delete the plugin directory under `packages/ai/src/plugins/`.
2. Remove the import and the array entry in `packages/ai/src/registry.ts`.
3. TypeScript compile reports any feature code that referenced the deleted plugin by id (unusual; features should only reference capabilities). Fix those.
4. The associated GitHub release stays put as long as any past Photosphere version might still try to download it.
5. Optionally add the plugin id to a "removed-plugins" list so the cache cleaner deletes the local model directory on next launch.

---

## Versioning and upgrades

- Bumping a model version is a new resource id (`siglip2-base-v1.0` -> `siglip2-base-v1.1`), new GitHub release tag, new SHA-256, all updated in the same source commit.
- On the user's machine, the new model downloads to a new cache subdirectory. The old one stays until the cache cleaner runs.
- A cache cleaner pass runs at app launch in the background: it walks the models cache, compares against `allPlugins[*].resources[*].id`, and deletes anything no longer referenced.
- Rollback is a code revert: change the resource id back, ship the binary, and the resource manager finds the old cached file or re-downloads the old tag.

---

## Testing

- **Unit tests per plugin**: each plugin gets a unit test that exercises its capability with a stub `IResourceManager` returning a fixture model path. Use small synthetic ONNX models where possible; if the real model is too big to keep in the test fixture, mark the test `skip` unless a `PHOTOSPHERE_AI_TESTS=full` env var is set.
- **Registry tests**: assert that every plugin in `allPlugins` is instantiable, declares non-empty `capabilities` and `id`, and has unique ids.
- **Resource manager tests**: stub the network layer; verify SHA mismatch is rejected, retry logic works, partial files are not surfaced.
- **Smoke test**: in the existing CLI smoke suite, add a plugin that does no real work but exercises the full `init -> getCapability -> use -> dispose` lifecycle. Catches integration regressions when plugin code changes.
- **Offline mode**: env var `PHOTOSPHERE_AI_OFFLINE=1` makes `IResourceManager.ensure()` throw if a resource is not pre-cached. Use this in CI so test runs never hit the network.

---

## Where this lives in the repo

```
packages/ai/
    src/
        types.ts                    # Core interfaces: IAiPlugin, IPluginResource, IPluginContext
        capabilities.ts             # Capability interfaces: IImageEmbedder, IFaceDetector, ...
        plugin-registry.ts          # AiPluginRegistry implementation
        resource-manager.ts         # Download, verify, cache
        registry.ts                 # The single list of all plugins compiled into the build
        plugins/
            siglip-image-embedder/
            siglip-text-embedder/
            scrfd-face-detector/
            buffalo-face-embedder/
            florence2-caption/
            geonames-geocoder/
        test/
            plugin-registry.test.ts
            resource-manager.test.ts
            plugins/
                siglip-image-embedder.test.ts
                ...
```

The CLI and Electron both depend on `packages/ai`. Features (search, face recognition, captioning) live in `packages/user-interface` or feature-specific packages and depend on `packages/ai` only through the capability interfaces.

---

## Recap

- One interface (`IAiPlugin`), one registry file, one resource manager. That is the entire plugin system.
- Code is compile-time pluggable: one line edit to add or remove a plugin.
- Models ship via GitHub releases, downloaded on first use, verified by SHA, cached in the user data dir, shared between CLI and Electron.
- Feature code references capabilities, never concrete plugins, so swapping models is cheap.
- No dynamic loading, no marketplace, no per-collection config. Resist scope creep.
