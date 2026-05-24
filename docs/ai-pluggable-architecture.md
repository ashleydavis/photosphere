# Pluggable AI Integration

Companion to [ai-implementation-priorities.md](ai-implementation-priorities.md) and [ai-integration-options.md](ai-integration-options.md). Those docs decide *what* to build. This one describes the *shape* the AI integration should take so individual features stay loosely coupled, easy to add, and easy to remove.

The architecture has two halves:
- **Code is compile-time pluggable**. Every AI feature is a self-contained plugin module behind a small interface. The set of active plugins is a single registry file. All plugin code is bundled into the Bun single-exe CLI and the Electron installer; there is no dynamic loading from disk at runtime.
- **Models are runtime pluggable**. Each plugin declares its model assets in a manifest. Photosphere downloads the assets from GitHub releases on first use, verifies SHA-256, and caches them in the user data dir. Each model has its own repository (with its own release history) so models can be versioned and shipped independently; small related models may share a "family" repo.

> **Note**: This doc was audited 2026-05-24 after several claims turned out to be wrong on follow-up verification. Most of this doc is *proposal*, not external claim, but each section below ends with an "**Audit & sources**" block listing what is verified (with URLs), what is unverified or wrong, and which identifiers are invented design proposals.

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

The integration splits across three kinds of workspace package:

- `packages/ai` — core contracts only (`IAiPlugin`, capability interfaces, `IPluginContext`, `IResourceManager`, `AiPluginRegistry`). Knows nothing about specific plugins, depends on no plugin package.
- `plugins/<plugin-id>` — one workspace package per plugin under a top-level `plugins/` directory (not `packages/`, so plugins are visually separate from core infrastructure). Each depends on `packages/ai` for the contracts and owns its own dependencies, resource declarations, and unit tests. Adding or removing a plugin is creating or deleting one of these packages.
- `plugins/registry` — depends on `packages/ai` and on every plugin package. Exports the single `allPlugins` array. The only place that imports plugins by name; everything else asks the registry for capabilities.

**Rule**: under `plugins/`, only plugin packages and the single `registry/` composition package. Anything else belongs under `packages/`. This keeps `plugins/` scannable: every directory there is either a plugin or the thing that lists them.

The root `package.json` workspaces glob needs to include `plugins/*` alongside the existing `packages/*` and `apps/*` entries.

**Audit & sources**:
- All interface names introduced below (`IAiPlugin`, `IPluginContext`, `IPluginResource`, `IResourceManager`, `IGithubReleaseRef`, `IImageEmbedder`, `ITextEmbedder`, `IFaceDetector`, `IFaceBox`, `IAiPluginConstructor`, `AiPluginRegistry`, `AiCapability`) — *invented design proposals*, not existing types. `IAiPluginConstructor` is referenced later in the doc but never explicitly defined; treat as conceptual (a constructor producing an `IAiPlugin`).
- The three-workspace split (`packages/ai`, `plugins/<plugin-id>`, `plugins/registry`) — *invented design proposal*.
- "The root `package.json` workspaces glob needs to include `plugins/*` alongside the existing `packages/*` and `apps/*` entries" — [UNVERIFIED]. The repo does have both `packages/*` and `apps/*` directories and uses Bun, which strongly implies workspaces, but I have not opened the root `package.json` to verify the current globs.

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
// plugins/registry/src/index.ts

import { SiglipImageEmbedderPlugin } from "siglip-image-embedder";
import { SiglipTextEmbedderPlugin } from "siglip-text-embedder";
import { ScrfdFaceDetectorPlugin } from "scrfd-face-detector";
import { BuffaloFaceEmbedderPlugin } from "buffalo-face-embedder";
import { Florence2CaptionPlugin } from "florence2-caption";
import { GeonamesGeocoderPlugin } from "geonames-geocoder";
import type { IAiPluginConstructor } from "ai";

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

**Audit & sources**:
- `plugins/registry/src/index.ts` file path, the example imports from `siglip-image-embedder`, `scrfd-face-detector`, etc. — *invented design proposals*; none of these plugin packages exist yet.
- `IAiPluginConstructor` import from `"ai"` — referenced but the type is not defined in the doc. Treat as conceptual.
- `AiPluginRegistry` class, its methods (`init`, `getCapability`, `disable`, `enable`), and the `byCapability` indexing scheme — *invented design proposal*.

---

## Model resources via GitHub releases

Each model gets its own GitHub repository (or a small family of related models shares one). There is no monolithic models repo. Models are released independently, on their own cadence, with their own version history and issues.

**Repo layout**:
- One repository per model. Examples: `photosphere-siglip2-base`, `photosphere-scrfd-10g`, `photosphere-florence2-base`.
- Small related models may share a "family" repo if it would be silly to split them. Example: `photosphere-face-models` could hold both SCRFD (detector) and InsightFace buffalo_l (embedder) if they always version together. Default is one model = one repo.
- Inside each model repo, one release per model version. Tag format is just `v<model-version>` (e.g. `v1.0`, `v1.1`). The repo name carries the model identity; the tag carries the version.
- Tags are immutable. A new model version is a new release with a new tag in that model's repo, never an in-place asset replacement.

**Why GitHub releases, one repo per model**:
- Each model has its own release history, release notes, and issue tracker. Bumping SigLIP never touches the Florence-2 repo.
- Public release downloads do not consume GitHub API rate limits because the download is a redirect to GitHub's object storage. Unauthenticated downloads scale.
- Asset URLs are stable and predictable: `https://github.com/<owner>/<model-repo>/releases/download/<tag>/<asset>`.
- No infrastructure to run, no third-party account, no bills.
- Permissioning is per-repo: a model-upload bot for SigLIP can have write access to just `photosphere-siglip2-base`.

**Asset conventions**:
- One asset per resource. Do not bundle multiple files into a tarball: the resource manager handles one file at a time and partial caches must be possible.
- Provide a sibling `<asset>.sha256` file in the same release for human verification. Photosphere does not read it; it carries its own copy of the hash compiled in.
- Keep individual assets under 2GB (GitHub's per-asset limit). Split larger models across multiple resources if needed.
- Never point Photosphere at a third-party repo you do not control. They can re-upload an asset under the same tag, which would silently change the file under your SHA pin (download then SHA-fail). Mirror upstream models into a repo you own.

**Manifest in code**:
Each plugin declares its resources statically:

```typescript
// plugins/siglip-image-embedder/src/index.ts

const SIGLIP2_MODEL_RESOURCE: IPluginResource = {
    id: "siglip2-base-v1.0",
    sizeBytes: 419_430_400,
    sha256: "a1b2c3...e4f5",
    githubRelease: {
        owner: "ashleydavis",
        repo: "photosphere-siglip2-base",   // one repo per model
        tag: "v1.0",                        // version only; the repo carries the model identity
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

**Audit & sources**:
- "Each file included in a release must be under 2 GiB" — [VERIFIED]: [GitHub: About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases). The doc says "under 2GB" — the limit is actually 2 *GiB*, plus 1000 assets per release, and no total or bandwidth limit.
- Asset URL pattern `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` — [VERIFIED]: this is the documented GitHub release asset URL convention.
- "Public release downloads do not consume GitHub API rate limits because the download is a redirect to GitHub's object storage" — [PARTIALLY VERIFIED]. The unauthenticated GitHub API rate limit is 60/hr per [REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api); release asset URLs do redirect to object storage. I did not find explicit GitHub documentation stating that the redirected download itself is uncounted — this is widely-believed practice but not officially confirmed in what I read.
- "Permissioning is per-repo" — [VERIFIED] as general GitHub behaviour (collaborators are per-repo).
- "Never point Photosphere at a third-party repo you do not control. They can re-upload an asset under the same tag" — [VERIFIED]. GitHub release tags are mutable: a repo owner can delete a release and re-create it with the same tag, changing the asset. Source: [GitHub: About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
- Example repo names (`photosphere-siglip2-base`, `photosphere-scrfd-10g`, `photosphere-florence2-base`, `photosphere-face-models`) — *illustrative proposals*, not real repos.
- Example SHA `"a1b2c3...e4f5"` — placeholder, not a real hash.
- "ashleydavis" example owner — placeholder; the actual GitHub owner is the user's choice.

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

**Audit & sources**:
- Cache directory paths (`$XDG_DATA_HOME/photosphere/models/...` on Linux, `~/Library/Application Support/photosphere/...` on macOS, `%APPDATA%\photosphere\models\...` on Windows) — [UNVERIFIED]. These match each platform's standard convention, but I did NOT verify that Photosphere currently uses these paths. Before adopting, read `apps/cli` and `apps/desktop` to see how Photosphere currently resolves user data directories.
- `ResourceUnavailableError` typed error class — *invented design proposal*.
- "Exponential-backoff retry (max 3 attempts)" — *invented design proposal*, not a standard or referenced policy.
- "Atomic rename" pattern for crash-safe writes — [VERIFIED] as standard POSIX behaviour (`rename(2)` is atomic on the same filesystem); not a specific URL needed.
- Existing background-tasks system reference (`docs/background-tasks.md`) — [VERIFIED]: file is referenced in [CLAUDE.md](../CLAUDE.md) and exists at [docs/background-tasks.md](background-tasks.md).
- "First the first time a feature calls `getCapability(...)`" lazy-download behaviour — *invented design proposal*.

---

## Adding a new plugin (worked example)

Suppose we want to add an OpenCLIP plugin as an alternative image embedder.

1. Create a new workspace package `plugins/openclip-image-embedder/` with its own `package.json` (depending on `ai`), `tsconfig.json`, and `src/index.ts`. Implement `IAiPlugin` and `IImageEmbedder`. Declare the OpenCLIP ONNX resource.
2. Create a new GitHub repo for this model, e.g. `photosphere-openclip-vitb32`. Upload the ONNX file as the asset on release `v1.0`. Compute the SHA-256, paste it (plus the repo coordinates) into the resource declaration.
3. Add `openclip-image-embedder` to `plugins/registry/package.json` dependencies.
4. Add one import line and one array entry to `plugins/registry/src/index.ts`.
5. Add a unit test inside the new plugin package that instantiates the plugin and verifies it implements `IImageEmbedder` (uses a stub `IPluginContext` that pretends the model is already cached).
6. Done. The semantic search feature picks it up automatically through the registry.

Total surface area touched: one new workspace package, one new model repo, one dependency entry, one import + array entry, one unit test.

**Audit & sources**:
- This entire walkthrough is *aspirational*: the OpenCLIP plugin, the `photosphere-openclip-vitb32` repo, and the `plugins/registry` package do not exist. The steps describe what *would* be needed once the architecture is implemented.

---

## Removing a plugin

1. Remove the import and the array entry in `plugins/registry/src/index.ts`.
2. Remove the dependency from `plugins/registry/package.json`.
3. Delete the `plugins/<plugin-id>/` workspace package.
4. TypeScript compile reports any feature code that referenced the deleted plugin by id (unusual; features should only reference capabilities). Fix those.
5. The associated model repo and its releases stay put as long as any past Photosphere version might still try to download from it.
6. Optionally add the plugin id to a "removed-plugins" list so the cache cleaner deletes the local model directory on next launch.

---

## Versioning and upgrades

- Bumping a model version is a new resource id (`siglip2-base-v1.0` -> `siglip2-base-v1.1`), new GitHub release tag, new SHA-256, all updated in the same source commit.
- On the user's machine, the new model downloads to a new cache subdirectory. The old one stays until the cache cleaner runs.
- A cache cleaner pass runs at app launch in the background: it walks the models cache, compares against `allPlugins[*].resources[*].id`, and deletes anything no longer referenced.
- Rollback is a code revert: change the resource id back, ship the binary, and the resource manager finds the old cached file or re-downloads the old tag.

**Audit & sources**:
- The cache cleaner pass, the "removed-plugins" list, and the rollback procedure are all *invented design proposals*. No code implements them today.

---

The architecture is built so the default `bun test` run never loads real model weights and never touches the network. Each plugin is its own workspace package and owns its own test suite under `src/test/`, following Photosphere's existing conventions (`test(...)` not `it(...)`, four-space indentation, no `any` in production code).

**Per-plugin unit tests** (`plugins/<plugin-id>/src/test/<plugin-id>.test.ts`):
- Assert the plugin instantiates and declares non-empty `id`, `name`, `capabilities`, and `resources`.
- Assert it satisfies its claimed capability interfaces — compile-time via a type-level assignment in the test file, runtime via shape checks on the returned methods.
- Exercise the plugin's *pure* logic: input preprocessing (image decode, resize, normalisation), output decoding (logit-to-label, bbox post-processing, NMS), threshold tuning. Hand-rolled fixtures, no ONNX weights loaded.
- Stub `IPluginContext` so `resources.ensure()` returns a known path. The stub fails loudly if the plugin asks for a resource it did not declare.

**Capability conformance suite** (`packages/ai/src/test/capability-conformance.ts`):
- A reusable harness that runs the same input through any plugin claiming a given capability and asserts the output contract: image embeddings are unit-length and the expected dimension; face bboxes lie inside the input image; text embeddings live in the same space as image embeddings (cosine similarity above a floor on a known pair).
- Each plugin's own test file imports this harness and points it at the plugin under test, with a fixture or a tiny synthetic model.
- Catches contract violations before a new plugin reaches the registry.

**Resource manager tests** (`packages/ai/src/test/resource-manager.test.ts`):
- Stub the HTTP layer. Assert: cache hit returns immediately, cache miss triggers download, SHA mismatch is rejected and retried, partial files are never surfaced as cached, atomic rename is used so a crashed download cannot poison the cache, side-loaded files are accepted if their SHA matches the declared resource.

**Registry tests** (`plugins/registry/src/test/registry.test.ts`):
- `allPlugins` contains no duplicate plugin ids and no duplicate human-readable `name`s.
- Every capability that feature code depends on has at least one plugin providing it (parameterised by an allowlist of required capabilities derived from the active features).
- Every plugin in `allPlugins` is instantiable with a stub `IPluginContext`. Catches missing constructor wiring and circular imports.

**Integration tests** (slow, opt-in):
- For each capability, one end-to-end test using a tiny real ONNX model (synthetic or aggressively quantized, kept under ~5MB so it can be committed as a test fixture inside the plugin package) to verify the full `init -> ensure -> use -> dispose` flow against an actual ONNX Runtime.
- Skipped by default. Run with `PHOTOSPHERE_AI_TESTS=full bun test`. Keeps `bun test` fast on every commit.

**Smoke tests** (Photosphere's existing CLI / Electron smoke harness):
- One smoke test per AI feature: `photosphere index <tmp-library>` on a 5-photo fixture exercises the full ONNX -> embedding -> bdb -> search path; `photosphere recognize`, `photosphere caption`, and `photosphere find-duplicates` each get the same treatment.
- The smoke harness pre-seeds the model cache from committed fixture files before invoking the CLI, so the smoke run never hits the network.
- These are the only tests that load real ONNX Runtime and exercise the file storage + bdb layers together, end-to-end.

**CI rules**:
- `PHOTOSPHERE_AI_OFFLINE=1` is set for every test run. `IResourceManager.ensure()` throws on cache miss, so a test that accidentally hits a real download fails loudly instead of silently pulling hundreds of MB.
- Outbound network is denied at the runner level as a belt-and-braces measure.
- A new plugin is not mergeable until it has: per-plugin unit tests, a capability-conformance pass, and a smoke-test entry that exercises it through the CLI. The registry test asserts every plugin id appears in the smoke fixtures, so omitting one is a CI failure rather than a runtime surprise.

**Audit & sources**:
- Photosphere uses Jest with `test(...)` (not `it(...)`) and tests under `src/test/` — [VERIFIED]: stated in [CLAUDE.md](../CLAUDE.md).
- `PHOTOSPHERE_AI_OFFLINE=1` and `PHOTOSPHERE_AI_TESTS=full` environment variables — *invented design proposals*. I made up the names.
- The capability-conformance harness (`packages/ai/src/test/capability-conformance.ts`) — *invented design proposal*.
- All test file paths (`plugins/<plugin-id>/src/test/<plugin-id>.test.ts`, etc.) — *invented design proposals*, follow the project's existing `src/test/` convention.
- "Existing CLI / Electron smoke harness" — [VERIFIED] in spirit: [CLAUDE.md](../CLAUDE.md) documents `bun run test:cli` and `bun run test:electron`. The specific pre-seeding pattern is a proposal.
- "Network access is denied at the runner level" — *invented design proposal*, not a current CI configuration I have verified.

---

## Where this lives in the repo

```
packages/
    ai/                                      # Core contracts. No plugin imports.
        src/
            types.ts                         # IAiPlugin, IPluginResource, IPluginContext, IResourceManager
            capabilities.ts                  # IImageEmbedder, IFaceDetector, ...
            plugin-registry.ts               # AiPluginRegistry class
            resource-manager.ts              # Download, verify, cache
        test/
            plugin-registry.test.ts
            resource-manager.test.ts

plugins/                                     # Each plugin is its own workspace package.
    siglip-image-embedder/
        package.json                         # Depends on "ai".
        tsconfig.json
        src/
            index.ts                         # SiglipImageEmbedderPlugin class
        test/
            siglip-image-embedder.test.ts

    siglip-text-embedder/
    scrfd-face-detector/
    buffalo-face-embedder/
    florence2-caption/
    geonames-geocoder/

    registry/                                # The single list of all plugins.
        package.json                         # Depends on "ai" and every sibling plugin package.
        src/
            index.ts                         # exports allPlugins: IAiPluginConstructor[]
        test/
            registry.test.ts
```

The CLI and Electron both depend on `plugins/registry` (which transitively pulls in `packages/ai` and every active plugin). Features (search, face recognition, captioning) live in `packages/user-interface` or feature-specific packages and depend on `packages/ai` only, through the capability interfaces, never on a concrete plugin package.

**Audit & sources**:
- The entire directory tree shown above (`packages/ai/`, `plugins/<plugin-id>/`, `plugins/registry/`) is an *invented design proposal*. None of these packages currently exist.
- `packages/user-interface`, `packages/storage`, `packages/mcp-tools` references — [VERIFIED]: all three exist in the repo (`ls packages/` confirms). Their internal structure has not been audited here.
- "matches how, e.g., `packages/mcp-tools` is structured" (cited earlier as an analogy) — [UNVERIFIED]. `packages/mcp-tools` exists but I have not opened it to verify the structural analogy.

---

## Recap

- One interface (`IAiPlugin`) in `packages/ai`, one workspace package per plugin under `plugins/`, one registry composition package at `plugins/registry`. That is the entire plugin system.
- Code is compile-time pluggable: a new plugin is a new workspace package plus one import line in `plugins/registry/src/index.ts`.
- Models ship via per-model GitHub repositories (one repo per model, or one per small-model family), released independently. Downloaded on first use, verified by SHA, cached in the user data dir, shared between CLI and Electron.
- Feature code references capabilities, never concrete plugins, so swapping models is cheap.
- No dynamic loading, no marketplace, no per-collection config. Resist scope creep.
