# What to Actually Build (AI for Photosphere)

Companion to [ai-integration-options.md](ai-integration-options.md). That doc is the catalog. This one is the decision.

Build these six things, in this order. Stop after each one and ship it.

---

## 1. CLIP semantic search (FIRST. Do this before anything else.)

**What**: embed every photo and every search query into the same vector space so users can type "sunset on the beach" or "kids opening presents" and get matching photos. No tags required.

**Why first**: it is the single highest-leverage AI feature. It is also the foundation that makes everything later cheaper. Once you have embeddings stored per photo you get image-to-image search, duplicate detection, auto-albums, and "find similar" for free.

**Pick**:
- Model: **SigLIP 2 (base)** via ONNX Runtime. Stronger than OpenAI CLIP, similar cost, multilingual. Fallback: OpenCLIP ViT-B/32 if SigLIP 2 ONNX export is a pain.
- Vector store: **sqlite-vec**. Matches Photosphere's file-based collection model, no extra service, one DB per library. (If a collection ever moves to Postgres, swap to pgvector.)
- Acceleration: CoreML on Mac, CUDA/DirectML on Windows/Linux, CPU fallback. ONNX Runtime gives you all three from one model.

**Ship when**: typing a natural-language query in the desktop UI returns relevant photos in under 500ms from a 50k-photo library.

---

## 2. Face recognition with named people (SECOND. Your stated #1 ask.)

**What**: detect faces, cluster them, let the user name a cluster, auto-tag every future photo against named clusters. "Show me photos of Alice" works.

**Pick**:
- Detector: **SCRFD** (ONNX, what PhotoPrism switched to in April 2026, better recall than the old Pigo).
- Embedder: **InsightFace buffalo_l (ArcFace)**. This is what Immich uses. Same ONNX runtime as #1.
- Clusterer: **HDBSCAN** on the embeddings, with a "this is/isn't X" feedback loop that re-clusters incrementally.
- UI: cluster grid, rename, merge, split, hide, "this is not me".

**Ship when**: user can name 5 clusters and search "photos of Alice and Bob" and get correct results, including on newly-imported photos.

---

## 3. Location enrichment (THIRD. Almost free, big UX win.)

**What**: parse EXIF GPS, reverse-geocode to country/city/suburb/POI names, cluster photos into "trips" by time+location.

**Pick**:
- Reverse geocoder: **self-hosted Nominatim** if you want zero external deps, or **Photon** for nicer UX. Cache results per coordinate.
- Trip clustering: DBSCAN on (timestamp, lat, lon).
- UI: map view, "trips" auto-album, "near here" search.

**No ML model required.** This is mostly plumbing. Do not skip it just because it is not AI: the location names become text that #1's CLIP index and #6's MCP server both use.

**Ship when**: "photos in Tokyo" works and "Trip to Tokyo 2024" auto-album appears.

---

## 4. Caption + tag generation via local vision LLM (FOURTH. This is the "animals" part.)

**What**: for every photo, generate one sentence describing it ("a Border Collie running on a beach at sunset") and a short tag list ("dog, beach, sunset, ocean, animal:border_collie"). Index the caption text into your existing search.

This is how you cover species recognition without shipping a separate iNaturalist model: vision LLMs identify common species, breeds, and landmarks well enough for a personal library. Specialist models can come later if users complain.

**Pick**:
- Default: **Florence-2 (base)**. Tiny, fast, runs on CPU, generates surprisingly good captions and tags. Use this for the auto pipeline.
- Optional upgrade: **Llama 3.2 Vision 11B via Ollama** for users with a GPU who want richer captions. Make this a setting, not the default. (PhotoPrism takes this approach.)
- Storage: caption goes into the existing text-search index AND gets re-embedded by #1 for stronger semantic recall.

**Ship when**: every newly-imported photo gets a caption within a few seconds on an average laptop, and "photos of dogs" (which never had a manual tag) finds them.

---

## 5. Duplicate and near-duplicate detection (FIFTH. Library hygiene.)

**What**: find exact duplicates, near-duplicates (resized, recompressed, watermarked), and burst-shot groups. Let the user review and bulk-delete.

**Pick**:
- Exact: SHA-256 of file bytes. You probably already have this.
- Near-duplicate fast pass: **pHash**. Cheap.
- Near-duplicate accurate pass: **cosine similarity on the CLIP embeddings you already computed in #1**. Zero new infrastructure.
- Best-of-burst (optional polish): Laplacian-variance sharpness + face eye-open detection. Pick a winner, hide the rest by default.

**Ship when**: a 50k library surfaces its duplicate groups in under a minute and the user can delete a group with one click.

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

**Ship when**: in Claude Desktop a user can ask "find the best 10 photos from my Tokyo trip with Alice in them and add them to a new album called Tokyo Highlights" and it works end-to-end.

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

**CLI**: the model runner. Build the ingest pipeline (steps 1, 2, 4, 5) as CLI commands so they can be run as batch backfill jobs (`photosphere index <library>`, `photosphere reindex --model siglip2`). The desktop app shells out to or shares code with the CLI for live ingest. The CLI is also where the MCP server (step 6) lives.

**Mobile (Capacitor, future)**: do not run models on phone in v1. Phone calls back to the desktop server over LAN for search and tagging. Add on-device OCR (Apple Vision / ML Kit) and on-device face detection only when capture-time features (scan business card, "who is this?" at the moment of taking the photo) become a priority.

---

## Order recap

1. CLIP semantic search (SigLIP 2 + sqlite-vec)
2. Face recognition with named clusters (SCRFD + InsightFace + HDBSCAN)
3. Location enrichment (Nominatim + trip clustering)
4. Caption + tags via vision LLM (Florence-2 default, Llama 3.2 Vision optional)
5. Duplicate detection (pHash + CLIP cosine)
6. MCP tool surface (finish existing work)

Do them in that order. Resist the urge to start two at once.
