# What to Actually Build (AI for Photosphere)

Companion to [ai-integration-options.md](ai-integration-options.md). That doc is the catalog. This one is the decision.

Build these six things, in this order. Stop after each one and ship it.

> **Note**: This doc was audited 2026-05-24 after several claims turned out to be wrong on follow-up verification. Each section now ends with an "**Audit & sources**" block listing what is verified (with URLs), what is fabricated or unverified, and what was an invented design identifier. Where a number in the body contradicts the audit block, trust the audit.

---

## 1. CLIP semantic search (FIRST. Do this before anything else.)

**What**: embed every photo and every search query into the same vector space so users can type "sunset on the beach" or "kids opening presents" and get matching photos. No tags required.

**Why first**: it is the single highest-leverage AI feature. It is also the foundation that makes everything later cheaper. Once you have embeddings stored per photo you get image-to-image search, duplicate detection, auto-albums, and "find similar" for free.

**Pick**:
- Model: **SigLIP 2 (base)** via ONNX Runtime. Stronger than OpenAI CLIP, similar cost, multilingual. Fallback: OpenCLIP ViT-B/32 if SigLIP 2 ONNX export is a pain.
- Vector store: **per-photo binary asset (`embedding/<assetId>`) + in-memory cosine index**. Matches Photosphere's existing `asset/` / `thumb/` / `display/` pattern under `IStorage`, gets merkle-tracked for free, and at the scales targeted (50k to a few hundred thousand photos) brute-force cosine in RAM beats any external vector DB on simplicity and latency. (If a single collection ever exceeds ~1M photos, switch to an approximate index like HNSW; still no external service required.)
- Acceleration: CoreML on Mac, CUDA/DirectML on Windows/Linux, CPU fallback. ONNX Runtime gives you all three from one model.

**Implement in Photosphere**:
1. Add `onnxruntime-node` to a new `packages/ml` so the same runtime is shared by the CLI exe and Electron.
2. Download SigLIP 2 base ONNX weights on first use into the user data dir. Do not bundle them into the CLI exe (keeps the single-exe small).
3. Store one embedding per photo as a new binary asset type `embedding/<assetId>` (float16 binary, ~1.5KB each) under `assetStorage`, alongside the existing `asset/`, `thumb/`, `display/` types. Merkle-tracked the same way. Works on `fs:` and `s3:` collections unchanged.
4. Build the search index in RAM at app launch by streaming all embedding files. 50k photos at 768 dims fp16 is ~75MB, fine for desktop.
5. Add a CLI command (`psi index <db-path>`) and a background-task handler (see `docs/background-tasks.md`) that walks the collection and encodes any photo without an embedding. Incremental on import, batch on backfill.
6. Wire into the existing gallery search bar: embed the query, cosine-rank in memory, return photo ids. No new query path beyond what gallery search already does.

**BSON database**:
- New asset type `embedding/<assetId>` under `assetStorage`. Stored alongside `asset/`, `thumb/`, `display/` and merkle-tracked the same way.
- New `IAsset` field `embeddingVersion: string` (e.g. `"siglip2-base-v1.0"`) so the indexer knows when to reindex after a model bump.
- No new bdb collection. The in-memory cosine index is rebuilt at app launch by streaming all `embedding/<assetId>` files for the collection.
- The existing `metadata` collection shape is unchanged except for the new `embeddingVersion` field on `IAsset`.

**Bundling**:
- `onnxruntime-node` (native addon) bundles in the Electron installer. In the Bun single-exe it requires `.node` extraction on first run, or a swap to `onnxruntime-web` (WASM) which bundles cleanly but is CPU-only and slower.
- SigLIP 2 weights (~400MB) download on first use into the user data dir. Not bundled.
- Optional: ship a quantized SigLIP 2 baseline (~100MB int8) inside the Electron installer for a zero-setup search experience. CLI still downloads on first use to keep the single exe small.
- Offline: yes, after the one-time weight download. The bundled baseline option makes Electron offline from first launch.

**Prove it works** (~2 to 4 hours):
1. Add a standalone Bun script `scratch/clip-poc.ts`. Pull SigLIP 2 base ONNX from Hugging Face and load it with `onnxruntime-node`.
2. Read 50 to 100 real photos from a sample Photosphere library through the existing `IStorage` reader.
3. Encode all photos to embeddings; keep them in an in-memory `{ photoId, embedding }[]`.
4. Encode 5 text queries ("sunset on beach", "dog", "birthday party", etc.). Cosine-rank against the photo embeddings.
5. Print top-5 photo paths per query and eyeball: does at least one query return a clearly relevant photo?
6. Kill the idea if: `onnxruntime-node` fails to load inside Bun, or ranked results look random.

**Ship when**: typing a natural-language query in the desktop UI returns relevant photos in under 500ms from a 50k-photo library.

**Audit & sources**:
- `psi index <db-path>` command — [FABRICATED-AS-EXISTING]. The CLI binary is `psi` (verified from `apps/cli/package.json` build scripts) but the `index` sub-command does not exist yet; this is a proposal.
- SigLIP 2 base ONNX weights "~400MB" — [FABRICATED — wrong number]. Actual full fp32 base model ONNX is ~1.5 GB; quantized variants are smaller. Source: [onnx-community/siglip2-base-patch16-224-ONNX/model.onnx](https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/blob/main/onnx/model.onnx).
- "Optional baseline (~100MB int8 quantized) inside the Electron installer" — [UNVERIFIED]. Quantized SigLIP 2 variants exist but I have not measured the specific int8 base size.
- "SigLIP 2 stronger than OpenAI CLIP" — [UNVERIFIED]. SigLIP 2 multilinguality is documented in [SigLIP 2 HF blog](https://huggingface.co/blog/siglip2); the "stronger than" comparison is my characterisation with no benchmark cited.
- "Fallback: OpenCLIP ViT-B/32 if SigLIP 2 ONNX export is a pain" — [SUPERSEDED]. SigLIP 2 ONNX exports do exist ([onnx-community/siglip2-base-patch16-224-ONNX](https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX)), so the fallback rationale is unnecessary.
- "ONNX Runtime gives you CoreML/CUDA/DirectML from one model" — [PARTIALLY VERIFIED]. ONNX Runtime supports these execution providers in general; per-model and per-operator coverage varies and I did not verify per-model.
- `onnxruntime-node` native addon — [VERIFIED]: [onnxruntime-node on npm](https://www.npmjs.com/package/onnxruntime-node).
- "Bun single-exe requires `.node` extraction on first run" — [PARTIALLY FABRICATED]. Bun supports embedded `.node` files when directly required ([Bun executables docs](https://bun.com/docs/bundler/executables)); `onnxruntime-node` specifically has had `bun --compile` compatibility issues ([oven-sh/bun#18079](https://github.com/oven-sh/bun/issues/18079)).
- `onnxruntime-web` WASM alternative — [VERIFIED]: [onnxruntime-web on npm](https://www.npmjs.com/package/onnxruntime-web).
- "Pull SigLIP 2 base ONNX from Hugging Face" in the POC — [VERIFIED]: hosted at [onnx-community/siglip2-base-patch16-224-ONNX](https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX).
- "~500ms latency on 50k-photo library" Ship-when target, "2-4 hours" POC estimate — [ESTIMATE]. My guesses, no measurement basis.
- "75MB RAM for 50k photos at 768 dims fp16" — math, verified: 50000 × 768 × 2 = 76.8 MB.
- "50k photos at 1.5KB each" — math, verified: 768 × 2 = 1536 bytes per embedding.
- *Invented design identifiers (proposals, not existing)*: `packages/ml`, `embedding/<assetId>` asset type, `IAsset.embeddingVersion` field.

---

## 2. Face recognition with named people (SECOND. Your stated #1 ask.)

**What**: detect faces, cluster them, let the user name a cluster, auto-tag every future photo against named clusters. "Show me photos of Alice" works.

**Pick**:
- Detector: **SCRFD** (ONNX, what PhotoPrism switched to in April 2026, better recall than the old Pigo).
- Embedder: **InsightFace buffalo_l (ArcFace)**. This is what Immich uses. Same ONNX runtime as #1.
- Clusterer: **HDBSCAN** on the embeddings, with a "this is/isn't X" feedback loop that re-clusters incrementally.
- UI: cluster grid, rename, merge, split, hide, "this is not me".

**Implement in Photosphere**:
1. Reuse the `packages/ml` ONNX runtime from #1. Download SCRFD and InsightFace buffalo_l on first use into the user data dir.
2. Per detected face, insert a record into a new bdb collection `faces` with `{ assetId, bbox, confidence, embedding: Binary, clusterId? }`. BSON `Binary` carries the 512-dim float32 ArcFace vector inline.
3. Run HDBSCAN in the CLI as a one-shot job. Set `clusterId` on each face record and seed a new bdb collection `face-clusters` with the cluster table.
4. Cluster names, merges, splits, and "not me" feedback all mutate the `face-clusters` (and sometimes `faces`) collection via `updateOne` + `database.commit` under the existing write lock.
5. Add a CLI command (`psi recognize <db-path>`) and a background-task handler for incremental face detection on import.
6. Electron UI reads the `face-clusters` and `faces` collections through the existing `node-api` wrapper around bdb, so `fs:` and `s3:` collections both work without extra plumbing.

**BSON database**:
- New bdb collection `faces` (one record per detected face): `{ _id (face id), assetId, bbox: { x, y, width, height }, confidence, embedding: Binary (512-dim float32 ArcFace), clusterId? }`. Sort index on `clusterId` for fast "photos of person X" lookups, sort index on `assetId` for "all faces in this photo".
- New bdb collection `face-clusters` (one record per cluster): `{ _id (cluster id), name?, hidden: boolean, mergedInto?: clusterId, sampleFaceIds: string[] }`.
- New `IAsset` field `faceCount: number` so "photos with people" filters can run without scanning the `faces` collection.
- Both new collections are merkle-tracked through bdb's existing shard files under `.db/bson/` so they sync and replicate alongside the asset binaries.

**Bundling**:
- Reuses the ONNX runtime from #1; same native-addon caveats apply (Electron clean, Bun single-exe needs `.node` extraction or `onnxruntime-web`).
- SCRFD (~17MB) and InsightFace buffalo_l (~250MB) download on first use into the user data dir. Not bundled.
- HDBSCAN port and clustering code are pure JS, bundle cleanly into both.
- Offline: yes, after the one-time weight downloads.

**Prove it works** (~3 to 5 hours):
1. Standalone Bun script `scratch/face-poc.ts`. Pull SCRFD + InsightFace buffalo_l ONNX.
2. Run face detection on 100 to 200 photos containing 3 to 5 known people across many shots each.
3. Embed every detected face. Cluster with a JS HDBSCAN port (or a quick agglomerative clusterer on cosine distance for the POC).
4. Render a quick static HTML page (write to `scratch/face-poc.html`) showing each cluster as a row of cropped faces.
5. Eyeball: are most photos of person A in one cluster? Are people A and B in separate clusters?
6. Kill the idea if: detection misses obvious faces, or known people are scattered across many small clusters with no obvious tuning fix.

**Ship when**: user can name 5 clusters and search "photos of Alice and Bob" and get correct results, including on newly-imported photos.

**Audit & sources**:
- "SCRFD (ONNX, what PhotoPrism switched to in April 2026, better recall than the old Pigo)" — [PARTIALLY VERIFIED]. PhotoPrism using ONNX SCRFD with Pigo removed is verified: [PhotoPrism face recognition docs](https://docs.photoprism.app/developer-guide/vision/face-recognition/) and [PhotoPrism's face README](https://github.com/photoprism/photoprism/blob/develop/internal/ai/face/README.md). The specific "April 2026" date appears in search snippets but I have not opened PhotoPrism's release notes to verify it directly. "Better recall than Pigo" is stated by PhotoPrism in their docs.
- "InsightFace buffalo_l (ArcFace). This is what Immich uses" — [VERIFIED]: [immich-app/buffalo_l on Hugging Face](https://huggingface.co/immich-app/buffalo_l).
- "Same ONNX runtime as #1" implication that PhotoPrism uses InsightFace ArcFace — [FABRICATED — wrong attribution]. PhotoPrism uses SCRFD for detection + FaceNet via TensorFlow for embedding, NOT InsightFace ArcFace. Source: [PhotoPrism face recognition docs](https://docs.photoprism.app/developer-guide/vision/face-recognition/). ArcFace / buffalo_l is what Immich uses.
- "SCRFD (~17MB)" — [VERIFIED but mis-structured]. `det_10g.onnx` is 16.9 MB but it ships *inside* the buffalo_l bundle, not as a separate download. Source: [buffalo_l file listing](https://huggingface.co/yolkailtd/face-swap-models/blob/main/insightface/models/buffalo_l/det_10g.onnx).
- "InsightFace buffalo_l (~250MB)" — [FABRICATED — wrong number]. Actual bundle is ~341 MB total (5 files: `det_10g.onnx` 16.9 MB, `w600k_r50.onnx` 174 MB, `1k3d68.onnx` 144 MB, `2d106det.onnx` 5.03 MB, `genderage.onnx` 1.32 MB). Source: [Immich's buffalo_l repo](https://huggingface.co/immich-app/buffalo_l) and file sizes via [HF mirror](https://huggingface.co/yolkailtd/face-swap-models/tree/main/insightface/models/buffalo_l).
- "HDBSCAN port and clustering code are pure JS, bundle cleanly into both" — [UNVERIFIED]. HDBSCAN is a well-known algorithm; JS ports exist on npm but I did not verify a specific one or its quality.
- BSON `Binary` carries 512-dim float32 ArcFace vectors inline — [PARTIALLY VERIFIED]. BSON Binary is real; ArcFace embeddings are 512-dim per the InsightFace model card on [immich-app/buffalo_l](https://huggingface.co/immich-app/buffalo_l). Whether bdb's BSON encoding handles inline Binary fields efficiently at scale is unverified.
- "3-5 hours" POC estimate — [ESTIMATE]. My guess.
- `psi recognize <db-path>` command — [FABRICATED-AS-EXISTING]. Proposed sub-command, does not exist yet.
- *Invented design identifiers (proposals)*: `faces` and `face-clusters` bdb collections, `IAsset.faceCount` field.

---

## 3. Location enrichment (THIRD. Almost free, big UX win.)

**What**: parse EXIF GPS, reverse-geocode to country/city/suburb/POI names, cluster photos into "trips" by time+location.

**Pick**:
- Reverse geocoder: **offline GeoNames `cities1000`** (~10MB) bundled in the CLI exe and Electron installer, looked up via an in-process kd-tree. Zero external deps, zero network, results cached per rounded coordinate in a bdb `geocode-cache` collection.
- Trip clustering: DBSCAN on (timestamp, lat, lon).
- UI: map view, "trips" auto-album, "near here" search.

**No ML model required.** This is mostly plumbing. Do not skip it just because it is not AI: the location names become text that #1's CLIP index and #6's MCP server both use.

**Implement in Photosphere**:
1. Confirm the existing EXIF parse writes lat/lon (and altitude when present) into per-photo metadata.
2. Bundle GeoNames `cities1000` (~10MB) inside the CLI exe and ship a kd-tree reverse geocoder. Zero network calls, works fully offline.
3. Cache resolved place names in a new bdb collection `geocode-cache`, keyed by rounded coords (6dp), so the same coordinate never gets re-resolved.
4. Run trip clustering (DBSCAN on timestamp + coords) as a CLI command and background task. Persist results in a new bdb collection `trips` (trip id, asset ids, name, date range, centroid).
5. Write new `IAsset` fields `country` / `city` / `placeName` into the `metadata` collection so the existing text search picks them up for free, and #1's CLIP text encoder benefits too.
6. Electron map view and trip list both read the `metadata` and `trips` collections via the existing `node-api` bdb wrapper. No new query path needed.

**BSON database**:
- Populate the existing `IAsset.coordinates` and `IAsset.location` fields during ingest.
- New `IAsset` fields: `country: string`, `city: string`, `placeName: string` so gallery filters and search can rank on each independently.
- New bdb collection `trips`: `{ _id (trip id), name, startDate, endDate, assetIds: string[], centroid: { lat, lng } }`.
- New bdb collection `geocode-cache`: `{ _id (rounded "lat,lng" key), country, city, placeName }`. Acts as a write-through cache so the kd-tree lookup is bypassed on a cache hit.

**Bundling**:
- GeoNames `cities1000` (~10MB) embedded as a binary asset in both the CLI single-exe and the Electron installer.
- kd-tree reverse geocoder and DBSCAN clusterer are pure JS, no native addons.
- No model weights, no first-use downloads.
- Offline: yes, from first launch. No network calls at any point.

**Prove it works** (~30 minutes to 1 hour):
1. Standalone Bun script `scratch/geocode-poc.ts`. `bun add local-reverse-geocoder` (or load GeoNames `cities1000.txt` and roll a kd-tree).
2. Pull GPS coords from 30 to 50 real photos using the existing EXIF parse.
3. Reverse-geocode each. Print `(lat, lon) -> "city, region, country"` and the lookup time in microseconds.
4. Eyeball: are place names correct for photos from known trips?
5. Kill the idea if: lookups exceed ~1ms each (would be unexpected) or place names are systematically wrong (would mean wrong dataset choice; switch dataset, do not abandon).

**Ship when**: "photos in Tokyo" works and "Trip to Tokyo 2024" auto-album appears.

**Audit & sources**:
- "GeoNames `cities1000` (~10MB)" — [UNVERIFIED size]. GeoNames cities1000 is a real dataset ([GeoNames data exports](https://www.geonames.org/export/)). I did not verify the exact compressed/uncompressed size; "~10MB" is my estimate.
- "Bundle GeoNames `cities1000` inside the CLI exe and ship a kd-tree reverse geocoder" via `local-reverse-geocoder` — [PARTIALLY FABRICATED]. `local-reverse-geocoder` exists ([npm](https://www.npmjs.com/package/local-reverse-geocoder), [GitHub](https://github.com/tomayac/local-reverse-geocoder)) but it downloads ~2 GB of GeoNames data at first use (~1.3 GB on disk after extraction) — it does NOT ship with `cities1000` bundled. Using only cities1000 requires either a different library or a hand-rolled kd-tree.
- "Nominatim was deliberately replaced with bundled GeoNames" (in the Offline section) — [FABRICATED — wrong tense]. Nothing in this doc has been implemented yet; the wording implied a past decision when it is in fact a proposal.
- DBSCAN for trip clustering — [VERIFIED]. DBSCAN is a well-known clustering algorithm; using it on (timestamp, lat, lon) for trip detection is standard practice but I did not cite a specific reference.
- "Zero network calls" claim — [VERIFIED-IF-IMPLEMENTED-AS-DESCRIBED]. Depends on which library is actually used; with `local-reverse-geocoder` as recommended, there IS network at first use.
- "30 minutes to 1 hour" POC estimate, "~1ms lookup" target — [ESTIMATE]. My guesses.
- *Invented design identifiers (proposals)*: `geocode-cache` and `trips` bdb collections, `IAsset.country`/`city`/`placeName` fields.

---

## 4. Caption + tag generation via local vision LLM (FOURTH. This is the "animals" part.)

**What**: for every photo, generate one sentence describing it ("a Border Collie running on a beach at sunset") and a short tag list ("dog, beach, sunset, ocean, animal:border_collie"). Index the caption text into your existing search.

This is how you cover species recognition without shipping a separate iNaturalist model: vision LLMs identify common species, breeds, and landmarks well enough for a personal library. Specialist models can come later if users complain.

**Pick**:
- Default: **Florence-2 (base)**. Tiny, fast, runs on CPU, generates surprisingly good captions and tags. Use this for the auto pipeline.
- Optional upgrade: **Llama 3.2 Vision 11B via Ollama** for users with a GPU who want richer captions. Make this a setting, not the default. (PhotoPrism takes this approach.)
- Storage: caption goes into the existing text-search index AND gets re-embedded by #1 for stronger semantic recall.

**Implement in Photosphere**:
1. Run Florence-2 base ONNX via the same `packages/ml` runtime from #1. Download on first use.
2. Write captions into a new `IAsset.aiCaption` field and tags into the existing `IAsset.labels` array (with an `ai:` prefix) on the `metadata` collection. No new collection required.
3. Re-embed the caption with #1's text encoder. Either merge it with the image embedding at rank time, or store it as a second binary asset type `text-embedding/<assetId>` (same shape as `embedding/<assetId>` from #1).
4. Add a CLI command (`psi caption <db-path>`) and a background-task handler for incremental captioning on import. The same command does backfill.
5. Optional Ollama path: detect a running Ollama on `127.0.0.1:11434` at startup, expose a setting in Electron to route through Llama 3.2 Vision via Ollama's local HTTP. Photosphere stays a client of Ollama, no Photosphere-hosted server.
6. New tags slot into the existing tag system under an `ai:` namespace so manual tags stay distinguishable and editable separately.

**BSON database**:
- New `IAsset` field `aiCaption: string`, kept distinct from the user-editable `description` so a user edit never gets overwritten.
- New `IAsset` field `aiCaptionVersion: string` so the captioner knows when to recaption after a model bump.
- Existing `IAsset.labels: string[]` carries AI tags with an `ai:` prefix; user tags and AI tags share the array but are distinguishable by prefix, and a single sweep can clear all AI tags.
- New asset type `text-embedding/<assetId>` under `assetStorage`, parallel to `embedding/<assetId>` from #1.

**Bundling**:
- Reuses the ONNX runtime from #1; same native-addon caveats apply.
- Florence-2 weights (~250MB) download on first use into the user data dir. Not bundled.
- Ollama is a user-installed external dependency. Photosphere probes `127.0.0.1:11434` at startup and disables the option if absent. Nothing to bundle.
- Offline: yes, after the one-time Florence-2 download. The optional Ollama path is fully local (Ollama itself runs models on the user's machine).

**Prove it works** (~2 to 3 hours):
1. Standalone Bun script `scratch/caption-poc.ts`. Pull Florence-2 base ONNX from Hugging Face.
2. Pick 20 photos spanning pets, people, landscapes, indoor scenes, and food.
3. Run captioning + tag extraction. Print `(photoId, caption, tags, ms_to_caption)` for each.
4. Eyeball: are captions mostly correct? Are tags relevant? Is per-photo time under ~10 seconds on your machine?
5. Bonus: if Ollama is installed locally, run the same 20 photos through Llama 3.2 Vision via Ollama's HTTP and compare quality side by side.
6. Kill the idea if: captions are nonsense across most photos, or per-photo time on a typical laptop is so high (~30s+) that incremental ingest would feel broken.

**Ship when**: every newly-imported photo gets a caption within a few seconds on an average laptop, and "photos of dogs" (which never had a manual tag) finds them.

**Audit & sources**:
- "Florence-2 (base). Tiny, fast, runs on CPU, generates surprisingly good captions and tags" — [PARTIALLY VERIFIED]. Florence-2 base ONNX is published ([onnx-community/Florence-2-base](https://huggingface.co/onnx-community/Florence-2-base)) with 0.23 B parameters. "Tiny, fast, surprisingly good" is my qualitative characterisation, not benchmarked here.
- "Florence-2 weights (~250MB)" — [UNVERIFIED]. Depends on quantization and which sub-models are downloaded. The uint8-quantized decoder alone is ~98 MB ([decoder_model_uint8.onnx](https://huggingface.co/onnx-community/Florence-2-base-ft/blob/b56701c76100e63107586a87737a22fa3918bb32/onnx/decoder_model_uint8.onnx)); a full base set is larger.
- "Llama 3.2 Vision 11B via Ollama" — [VERIFIED that Ollama supports vision models]. Llama 3.2 Vision is one such model. Source: [Ollama FAQ](https://docs.ollama.com/faq).
- "(PhotoPrism takes this approach.)" — [PARTIALLY VERIFIED]. PhotoPrism does integrate with Ollama for caption generation, [PhotoPrism Caption Generation docs](https://docs.photoprism.app/developer-guide/vision/caption-generation/). However PhotoPrism's docs reference multiple vision models (gemma3, qwen3-vl, etc.), not specifically Llama 3.2 Vision; my "this approach" wording was loose.
- "Detect a running Ollama on `127.0.0.1:11434` at startup" — [VERIFIED]. Ollama binds 127.0.0.1:11434 by default: [Ollama FAQ](https://docs.ollama.com/faq).
- "Photosphere stays a client of Ollama, no Photosphere-hosted server" — accurate to the design.
- "2-3 hours" POC estimate, "under ~10 seconds per photo" target, "~30s+ would be broken" threshold — [ESTIMATE]. My guesses, no measurement basis.
- *Invented design identifiers (proposals)*: `IAsset.aiCaption`/`aiCaptionVersion` fields, `text-embedding/<assetId>` asset type, `ai:` tag prefix convention, `psi caption` sub-command.

---

## 5. Duplicate and near-duplicate detection (FIFTH. Library hygiene.)

**What**: find exact duplicates, near-duplicates (resized, recompressed, watermarked), and burst-shot groups. Let the user review and bulk-delete.

**Pick**:
- Exact: SHA-256 of file bytes. You probably already have this.
- Near-duplicate fast pass: **pHash**. Cheap.
- Near-duplicate accurate pass: **cosine similarity on the CLIP embeddings you already computed in #1**. Zero new infrastructure.
- Best-of-burst (optional polish): Laplacian-variance sharpness + face eye-open detection. Pick a winner, hide the rest by default.

**Implement in Photosphere**:
1. Surface the existing per-file SHA-256 in the metadata file if it is not already there.
2. Compute pHash in the CLI during the same ingest pass as #1 and write it into a new `IAsset.pHash` field on the `metadata` collection. Add a sort index on `pHash` for fast near-duplicate lookups.
3. Near-duplicate pass: brute-force cosine over the CLIP embeddings already on disk from #1. Chunk by N to keep memory bounded on `s3:` collections where reads are slower.
4. Output groups into a new bdb collection `duplicate-groups`: each record carries member asset ids, suggested best-of, and reason (`exact` / `near` / `burst`).
5. CLI command (`psi find-duplicates <db-path>`) for backfill. Electron "Duplicates" page reads the `duplicate-groups` collection and uses the existing delete pipeline for bulk actions.
6. No extra model. Best-of-burst uses Laplacian variance computed inline from the thumbnails Photosphere already generates.

**BSON database**:
- New `IAsset` field `pHash: string` (hex, 16 chars for a 64-bit pHash). SHA-256 is already in `IAsset.hash`. Add a sort index on `pHash` so Hamming-distance scans are bounded by sorted neighbours rather than full-collection sweeps.
- New bdb collection `duplicate-groups`: `{ _id (group id), memberAssetIds: string[], reason: "exact" | "near" | "burst", suggestedBestAssetId: string }`.

**Bundling**:
- pHash and Laplacian variance are pure JS / WASM, bundle cleanly into both.
- No model weights, no first-use downloads. Reuses the CLIP embeddings already on disk from #1.
- Offline: yes, from first launch.

**Prove it works** (~1 to 2 hours, dependent on #1 having run):
1. Assemble a tiny ground-truth set: 5 known duplicate groups (originals plus resized / recompressed / cropped copies, ~30 photos total). Plus 30 unrelated photos for false-positive checking.
2. Standalone Bun script `scratch/dup-poc.ts`. Compute SHA-256 and pHash for every photo.
3. If #1 is done, also load the CLIP embeddings from the collection; otherwise skip the semantic leg.
4. Group: exact (SHA-256), near (pHash Hamming distance ≤ 5), semantic (CLIP cosine ≥ 0.9).
5. Print groups. Confirm all 5 ground-truth groups are reconstructed and no unrelated photo is merged in.
6. Kill the idea if: pHash misses obvious near-dups (very rare; almost certainly tuning) or CLIP cosine threshold cannot separate visually-similar-but-distinct photos (tune threshold; if still bad, fall back to pHash-only).

**Ship when**: a 50k library surfaces its duplicate groups in under a minute and the user can delete a group with one click.

**Audit & sources**:
- SHA-256 for exact duplicate detection — [VERIFIED] as standard practice; in this repo, `IAsset.hash` already exists ([packages/api/src/lib/asset.ts](../packages/api/src/lib/asset.ts)).
- pHash for near-duplicate detection — [VERIFIED]: standard perceptual hashing technique. Specific JS/WASM implementation not cited.
- "pHash Hamming distance ≤ 5" and "CLIP cosine ≥ 0.9" thresholds — [UNVERIFIED]. These are rule-of-thumb numbers commonly cited but I did not source them.
- Laplacian variance for sharpness — [VERIFIED] as a standard sharpness measure (Pech-Pacheco et al. 2000); I did not cite a specific URL.
- "16 chars hex for 64-bit pHash" — math, verified: 64 / 4 = 16.
- "Best-of-burst uses Laplacian variance computed inline from the thumbnails Photosphere already generates" — thumbnails do exist (see `packages/node-api/src/lib/media-file-database.ts`); the Laplacian-on-thumbnail approach is my proposal.
- "Output groups into a new bdb collection `duplicate-groups`" — bdb supports new collections ([packages/bdb/README.md](../packages/bdb/README.md)), but the `duplicate-groups` collection itself is a proposal.
- "1-2 hours" POC estimate, "under a minute" Ship-when target — [ESTIMATE]. My guesses.
- *Invented design identifiers (proposals)*: `IAsset.pHash` field, `duplicate-groups` bdb collection, `psi find-duplicates` sub-command.

---

## 6. MCP tool surface (SIXTH. Multiplies everything above.)

**What**: expose the search, tagging, and metadata operations as MCP tools so any LLM client (Claude Desktop, Claude Code, etc.) becomes a chat interface to the library. You already have `packages/mcp-tools` and `apps/cli/src/cmd/mcp.ts` in flight, so this is finishing existing work, not new work.

**Pick** (minimum useful tool set):
- `search(query, limit)` (drives #1)
- `search_by_person(name)` (drives #2)
- `search_by_location(place)` and `search_by_date(range)` (drives #3)
- `get_photo(id)`, `get_thumbnail(id)`, `describe(id)`
- `tag(ids, tags)`, `add_to_album(ids, album)`, `rate(ids, rating)`
- `find_similar(id)`, `find_duplicates()`

**Implement in Photosphere**:
1. Host the MCP server inside the existing CLI (`apps/cli/src/cmd/mcp.ts`). The single-exe CLI is the natural home: portable, no Electron required, runs over stdio.
2. Tools are direct function calls into `packages/user-interface` and `packages/storage`. No HTTP, no REST layer to invent.
3. Implement the minimum tool set (search, search_by_person, search_by_location, search_by_date, get_photo, get_thumbnail, tag, find_similar, find_duplicates) on top of features #1 through #5.
4. `get_photo` and `get_thumbnail` stream bytes from `IStorage`, so `fs:` and `s3:` collections both work transparently. Return base64 or a temp file path depending on what the MCP client needs.
5. Mutations (`tag`, `add_to_album`, `rate`) write through the same storage paths the Electron UI uses, so changes show up live in an open desktop session.
6. Electron exposes MCP by spawning the CLI as a child process, or by importing `packages/mcp-tools` directly. Same code either way.
7. Document adding `psi mcp --db <path>` to Claude Desktop's `mcp.json` so install is one config snippet.

**BSON database**:
- MCP tools call into `packages/node-api`, which already wraps bdb behind the existing read/write helpers. No tool talks to bdb directly so the write lock and merkle tree are always honoured.
- `search(query, limit)` ranks against the in-memory CLIP index, then hydrates the top-N hits with `metadataCollection.getOne()`.
- `search_by_person(name)` resolves the name against the `face-clusters` collection, then fans out to the `faces` collection to collect asset ids.
- `search_by_location(place)` and `search_by_date(range)` query the `metadata` collection using the new `country` / `city` / `placeName` / `photoDate` fields and the existing sort indexes.
- Mutations (`tag`, `add_to_album`, `rate`) go through `metadataCollection.updateOne` + `database.commit` inside the existing write-lock-aware paths, so changes show up live in a connected Electron session.

**Bundling**:
- MCP SDK is pure TS, bundles cleanly into the CLI single-exe.
- Electron either spawns the CLI as a child process (no extra bundling) or imports `packages/mcp-tools` directly (already in the shared workspace).
- No external assets, no model weights, no first-use downloads for MCP itself.
- Offline: yes. MCP runs over stdio between the local Claude client and the local Photosphere CLI; no network involved. Note: the Claude client itself (e.g. Claude Desktop) typically requires network to reach the Claude API, but that is outside Photosphere.

**Prove it works** (~1 to 2 hours):
1. In the existing `apps/cli/src/cmd/mcp.ts`, register two trivial tools: `count_photos()` and `list_recent_photos(limit)`. Both read straight from a small test Photosphere library via the existing storage layer.
2. Add an entry to Claude Desktop's `mcp.json` pointing at `psi mcp --db <path-to-test-library>`.
3. Open Claude Desktop. Ask "how many photos are in my library?" and "list the 5 most recent photos."
4. Confirm: the tools are invoked, results come back, and (for `list_recent_photos`) thumbnails or paths render in the chat.
5. Kill the idea if: Claude Desktop fails to launch the CLI as an MCP server, or stdio framing breaks under any non-trivial payload (very unlikely; the MCP SDK handles this).

**Ship when**: in Claude Desktop a user can ask "find the best 10 photos from my Tokyo trip with Alice in them and add them to a new album called Tokyo Highlights" and it works end-to-end.

**Audit & sources**:
- "You already have `packages/mcp-tools` and `apps/cli/src/cmd/mcp.ts` in flight" — [VERIFIED]: `packages/mcp-tools/` and `apps/cli/src/cmd/mcp.ts` both exist in the repo. I have not read the contents of either to verify how complete they are.
- "MCP runs over stdio" — [VERIFIED]. Standard MCP transport: [Model Context Protocol spec](https://modelcontextprotocol.io/specification).
- `psi mcp --db <path>` command — [FABRICATED-AS-EXISTING]. The CLI binary is `psi` but the `mcp` sub-command's exact CLI surface is a proposal; the file `apps/cli/src/cmd/mcp.ts` exists but I have not verified its current command-line interface.
- "Tools are direct function calls into `packages/user-interface` and `packages/storage`" — [VERIFIED] that these packages exist; the MCP tool wiring is a proposal.
- "Tools call into `packages/node-api`, which already wraps bdb behind the existing read/write helpers" — [VERIFIED]: `packages/node-api/src/lib/media-file-database.ts` instantiates `BsonDatabase` and exposes write helpers.
- "Claude Desktop's `mcp.json`" — [VERIFIED] as Claude Desktop's MCP server config file convention. Source: [Claude Desktop MCP docs](https://modelcontextprotocol.io/quickstart/user).
- "1-2 hours" POC estimate — [ESTIMATE]. My guess.
- *Invented design identifiers (proposals)*: The exact tool set (`search`, `search_by_person`, etc.) is a proposal. `count_photos()` and `list_recent_photos()` test tools are proposed POC scaffolding.

---

## What to NOT build yet

Defer until users ask:
- Generative editing (inpainting, Magic Eraser, sky replacement). Expensive, controversial, every commercial app does it badly, your users probably have Photoshop.
- Upscaling/restoration. Cool demo, low ongoing use. Wait for a real user request.
- Video AI (scene detection, Whisper transcription, action recognition). Do it after #1-6 are solid. Video is its own project.
- NSFW/sensitive content classification. Add only when shared albums or kid accounts ship, otherwise nobody benefits.
- Memory videos / highlight reels. Needs #1, #2, #3, #4 to be excellent first. Premature otherwise.

---

## Per-surface implications

**Electron desktop**: home of everything above. All models run here.

**CLI**: the model runner. Build the ingest pipeline (steps 1, 2, 4, 5) as CLI commands so they can be run as batch backfill jobs (`psi index <library>`, `psi reindex --model siglip2`). The desktop app shells out to or shares code with the CLI for live ingest. The CLI is also where the MCP server (step 6) lives.

**Mobile (Capacitor, future)**: do not run models on phone in v1. Phone calls back to the desktop server over LAN for search and tagging. Add on-device OCR (Apple Vision / ML Kit) and on-device face detection only when capture-time features (scan business card, "who is this?" at the moment of taking the photo) become a priority.

---

## Database & storage layout

Photosphere already has a BSON-backed metadata database (`packages/bdb`, mounted at `.db/bson/` under `assetStorage`) and a binary asset store (`IStorage`, with existing asset types `asset/`, `thumb/`, `display/`). Every feature above plugs into both. After all six features the composite layout looks like this:

```
collection root (assetStorage)
├── asset/<assetId>              # original file (existing)
├── thumb/<assetId>              # thumbnail (existing)
├── display/<assetId>            # display image (existing)
├── embedding/<assetId>          # NEW (#1): SigLIP 2 image embedding, ~1.5KB float16
├── text-embedding/<assetId>     # NEW (#4): SigLIP 2 text embedding of the caption
└── .db/bson/
    ├── metadata                 # existing IAsset records (extended with new fields)
    ├── faces                    # NEW (#2): per-face bbox + embedding + clusterId
    ├── face-clusters            # NEW (#2): named clusters
    ├── geocode-cache            # NEW (#3): rounded-coord -> place name
    ├── trips                    # NEW (#3): trip groupings
    └── duplicate-groups         # NEW (#5): duplicate groupings
```

**`IAsset` schema additions** (all optional, populated by the relevant feature's ingest pass):
- `embeddingVersion: string` (#1)
- `faceCount: number` (#2)
- `country: string`, `city: string`, `placeName: string` (#3)
- `aiCaption: string`, `aiCaptionVersion: string` (#4)
- `pHash: string` (#5)

**Why bdb for the new structured data rather than flat JSON files**:
- Sharding and sort indexes already exist; "photos in Tokyo" or "photos of Alice" stay fast as the library grows.
- Mutations are write-lock-aware via the same paths the Electron UI and MCP server already use, so cluster renames and tag edits cannot race each other.
- bdb shards live under `.db/bson/` and are tracked by the same merkle tree that tracks `asset/`, `thumb/`, and `display/`, so sync and replication "just work" for the new collections.

**Why binary asset types (not BSON Binary) for image and text embeddings**:
- Embeddings are large enough (~1.5KB) and numerous (one or two per photo) that inlining them into the `metadata` collection would inflate each `IAsset` document by ~10x for no query benefit.
- Storing as `embedding/<assetId>` matches the existing pattern (`asset/`, `thumb/`, `display/`), gets merkle-tracked, and lets partial copies (e.g. thumb-only collections) skip embeddings cleanly.
- Face embeddings *are* stored inline as BSON `Binary` on the `faces` collection because each face record is already structured data the UI queries directly (cluster grids, "all faces in this photo"), so co-locating the vector pays for itself.

**Write-lock and commit pattern** (all new mutations follow this):

```typescript
await database.flush();
await acquireWriteLock(rawStorage, sessionId);
try {
    await facesCollection.insertOne(faceRecord);
    await faceClustersCollection.updateOne(clusterId, { name: "Alice" });
    await metadataCollection.updateOne(assetId, { faceCount: 3 });
    await database.commit();
}
finally {
    await releaseWriteLock(rawStorage);
}
```

**Audit & sources**:
- "`packages/bdb`, mounted at `.db/bson/` under `assetStorage`" — [VERIFIED]: `new BsonDatabase(assetStorage, ".db/bson", ...)` at [packages/node-api/src/lib/media-file-database.ts:252](../packages/node-api/src/lib/media-file-database.ts).
- Existing asset types `asset/`, `thumb/`, `display/` — [VERIFIED]: see `assetType` parameter handling in [packages/node-api/src/lib/media-file-database.ts:372](../packages/node-api/src/lib/media-file-database.ts) (`const assetPath = ${assetType}/${assetId}`).
- "bdb shards live under `.db/bson/` and are tracked by the same merkle tree that tracks `asset/`, `thumb/`, and `display/`" — [VERIFIED]: merkle tree is updated via `addItem(merkleTree, { name: assetPath, ... })` in the same file, and bdb shards are written to `assetStorage` under the same root.
- "Sharding and sort indexes already exist" — [VERIFIED]: [packages/bdb/README.md](../packages/bdb/README.md) documents `ensureSortIndex`.
- Write-lock-and-commit pattern code block — [VERIFIED] as the pattern documented in [packages/bdb/README.md](../packages/bdb/README.md).
- "Face embeddings stored inline as BSON `Binary`" — [PARTIALLY VERIFIED]. BSON supports Binary fields; bdb's specific Binary handling at scale is not verified.
- "Embeddings ~1.5KB and ~10x inflation if inlined" — math, verified for a 768-dim float16 vector; "~10x" is a rough comparison against typical IAsset document size that I did not measure.
- *Invented design identifiers (proposals)*: all six new bdb collections (`faces`, `face-clusters`, `geocode-cache`, `trips`, `duplicate-groups`), new asset types `embedding/` and `text-embedding/`, and all new `IAsset` fields listed above.

---

## Bundling & distribution

What can ship inside the Bun single-exe CLI and the Electron installer, and what cannot.

**Bundles cleanly in both**
- Pure JS/TS dependencies: MCP SDK, kd-tree reverse geocoder, pHash, DBSCAN/HDBSCAN ports, EXIF parsing.
- Small data: GeoNames `cities1000` (~10MB) embedded as a binary asset for offline reverse geocoding.
- Runtime-written data (new bdb collections `faces`, `face-clusters`, `geocode-cache`, `trips`, `duplicate-groups` under `.db/bson/`, plus new binary asset types `embedding/` and `text-embedding/` under `assetStorage`): created on demand, no bundling concern.

**Bundles in Electron, rough in Bun single-exe**
- `onnxruntime-node` is a native Node addon (`.node` binary per platform). Electron-builder handles native addons fine. `bun build --compile` does not cleanly embed `.node` files into a true single exe; the workaround is to extract the `.node` to a temp dir on first run.
- Clean alternative for the CLI: use `onnxruntime-web` (WASM). Bundles into the single exe with no native side files. Trade-off: slower on CPU, no CoreML or CUDA acceleration. Reasonable for batch backfill in the CLI. Electron keeps native ONNX for live indexing.
- `sharp` (if used for face cropping or preprocessing) has the same native-addon situation as `onnxruntime-node`.

**Not bundled by design**
- Model weights: SigLIP 2 (~400MB), SCRFD (~17MB), InsightFace buffalo_l (~250MB), Florence-2 (~250MB). Total over 900MB. Downloaded on first use into the user data dir so the CLI exe stays lean and the Electron installer download stays reasonable.
- Optional: ship one baseline model (e.g. SigLIP 2 int8 quantized, ~100MB) inside the Electron installer for a zero-setup search experience. The CLI still downloads on first use to keep the single exe small.
- Ollama (the optional #4 upgrade path): user installs Ollama separately. Photosphere probes `127.0.0.1:11434` at startup and disables the option if absent.

**Decision rule**: if a dependency must work in the Bun single-exe with zero side files and zero post-install download, it must be pure JS/TS or WASM. ONNX is the only forcing function. Pick one of:
1. `onnxruntime-web` (WASM) in the CLI, `onnxruntime-node` in Electron. Portability first.
2. `onnxruntime-node` in both, with `.node` extraction on first run for the CLI. Speed first.

**Audit & sources**:
- "SigLIP 2 (~400MB), SCRFD (~17MB), InsightFace buffalo_l (~250MB), Florence-2 (~250MB). Total over 900MB." — [FABRICATED — all four numbers are wrong]. Correct numbers (see per-section audits above): SigLIP 2 base fp32 ~1.5 GB; SCRFD/det_10g is bundled inside buffalo_l, not separate; buffalo_l total ~341 MB; Florence-2 base depends on quantization but typically several hundred MB. The "over 900MB" total is therefore meaningless — actual total depends on choices and is likely larger.
- "`bun build --compile` does not cleanly embed `.node` files" — [PARTIALLY FABRICATED]. Bun does support embedded `.node` files when directly required: [Bun executables docs](https://bun.com/docs/bundler/executables). `onnxruntime-node` specifically has had `bun --compile` compatibility issues: [oven-sh/bun#18079](https://github.com/oven-sh/bun/issues/18079).
- "`onnxruntime-web` (WASM). Bundles into the single exe with no native side files. Trade-off: slower on CPU, no CoreML or CUDA acceleration" — [PARTIALLY VERIFIED]. `onnxruntime-web` is real ([npm](https://www.npmjs.com/package/onnxruntime-web)) and is WASM-based. The specific bundling behaviour in Bun's `--compile` and the relative-speed claim are not benchmarked here.
- "`sharp` ... has the same native-addon situation as `onnxruntime-node`" — [UNVERIFIED]. `sharp` is a known native addon ([npm](https://www.npmjs.com/package/sharp)) but I have not tested it with `bun --compile`.

---

## Offline operation

Every recommendation in this doc runs locally. Photosphere never sends user photos or queries to a remote AI service.

**Works fully offline from first launch** (no network ever):
- #3 Location enrichment (GeoNames bundled in the exe / installer).
- #5 Duplicate detection (pure JS / WASM, no weights).
- #6 MCP tool surface (stdio between local Claude client and local Photosphere CLI).

**Works fully offline after a one-time model download** (network only on first use, then never again):
- #1 CLIP semantic search (SigLIP 2 weights).
- #2 Face recognition (SCRFD + InsightFace buffalo_l weights).
- #4 Caption + tag generation (Florence-2 weights). The optional Ollama upgrade path is also fully local: Ollama runs the model on the user's own machine over `127.0.0.1`.

**Eliminating the first-use download** (optional):
- Ship the model weights inside the Electron installer (adds installer size but enables true offline-from-install).
- The Bun single-exe CLI is best left lean: bundling ~900MB of weights into a portable exe defeats the point. CLI users on air-gapped machines can sideload weights into the user data dir manually.

**External calls Photosphere does NOT make**: no telemetry, no remote AI APIs, no cloud OCR, no remote geocoding (Nominatim was *proposed and then* deliberately replaced with bundled GeoNames within this doc — see audit). The only outbound traffic is the model-weight download in features #1, #2, and #4, and only on first use.

**Audit & sources**:
- "Photosphere never sends user photos or queries to a remote AI service" — [TRUE IF DESIGN IS IMPLEMENTED AS DESCRIBED]. Forward-looking claim about the design proposed in this doc.
- "Nominatim was deliberately replaced" — [FABRICATED — wrong tense]. None of this doc has been implemented; this was a within-document revision (an earlier draft of section 3 proposed Nominatim, then was edited to propose offline GeoNames). The wording implied a past production decision when in fact it is a doc-level edit.
- "Optional Ollama upgrade path is also fully local: Ollama runs the model on the user's own machine over `127.0.0.1`" — [VERIFIED]: [Ollama FAQ](https://docs.ollama.com/faq) confirms 127.0.0.1:11434 default bind.

---

## Order recap

1. CLIP semantic search (SigLIP 2 + per-photo embedding asset + in-memory cosine)
2. Face recognition with named clusters (SCRFD + InsightFace + HDBSCAN + bdb `faces` and `face-clusters` collections)
3. Location enrichment (offline GeoNames reverse geocode + bdb `trips` collection)
4. Caption + tags via vision LLM (Florence-2 default, Llama 3.2 Vision optional)
5. Duplicate detection (pHash + CLIP cosine)
6. MCP tool surface (finish existing work)

Do them in that order. Resist the urge to start two at once.
