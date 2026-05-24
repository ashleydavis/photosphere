# AI Integration Options for Photosphere

A survey of possible AI features for Photosphere across the Electron desktop app, CLI tool, and future mobile app. This document only catalogs **options and ideas**, not architecture or implementation. Sourced from current industry practice (Immich, PhotoPrism, Google Photos, Apple Photos), academic work, and open-source projects.

> **Note**: This doc was audited 2026-05-24. The Sources section at the end of the doc lists URLs but they were not cited per-line when the doc was first written. Each major section below now ends with an "**Audit & sources**" block listing claims directly verified with URLs versus claims that rely on the (un-mapped) footer or remain unverified. Specific numeric claims (dates, percentages, "X+ species") should be treated as unverified unless explicitly linked.

---

## 1. People, Places and Animals (Recognition)

The user's primary interest. Each of these is a well-trodden problem with mature open-source models.

### 1.1 Face Detection and Recognition
Detect faces in photos, cluster them into groups of the same person, and let the user name those clusters. Subsequent photos auto-tag against named clusters.

- **Detection** (find faces in the image): RetinaFace, SCRFD (used by PhotoPrism since April 2026), MTCNN, MediaPipe Face Detection, YOLOv8-face.
- **Recognition** (embed each face into a vector for matching): InsightFace's ArcFace / buffalo_l (what Immich uses), FaceNet, DeepFace.
- **Clustering**: HDBSCAN, DBSCAN, or simple thresholded cosine similarity on the recognition embeddings.
- **Capabilities worth offering**: rename / merge / split clusters; "this is not me" negative feedback; hidden persons; co-occurrence ("photos of Alice AND Bob"); age progression view of a person over time; "me" pinning.

**Audit & sources**:
- "SCRFD (used by PhotoPrism since April 2026)" — [PARTIALLY VERIFIED]. PhotoPrism using ONNX SCRFD as its face detector (with the legacy Pigo removed) is documented at [PhotoPrism face recognition docs](https://docs.photoprism.app/developer-guide/vision/face-recognition/) and [PhotoPrism's face README](https://github.com/photoprism/photoprism/blob/develop/internal/ai/face/README.md). The specific date "April 2026" appears in search snippets quoting PhotoPrism release notes but I did not open the release notes directly.
- "InsightFace's ArcFace / buffalo_l (what Immich uses)" — [VERIFIED]: [immich-app/buffalo_l on Hugging Face](https://huggingface.co/immich-app/buffalo_l).
- "RetinaFace, MTCNN, MediaPipe Face Detection, YOLOv8-face, FaceNet, DeepFace" — name-dropped model list, all are real models but not individually re-verified in this audit pass.
- "HDBSCAN, DBSCAN" — standard clustering algorithms.

### 1.2 Animal / Pet Recognition
Two distinct problems, often conflated:

- **Species identification** ("this is a Border Collie", "this is a Magpie"). Best models come from the iNaturalist / Pl@ntNet ecosystem. iNaturalist's CV model identifies 10,000+ species and adds new ones every ~1.7 hours. Models are downloadable for offline use.
- **Individual pet recognition** ("this is *my* dog Rex", not just "a dog"). Treat the same as face recognition but on animals; PetFace, dog-face embedding models, or fine-tuned ArcFace on user-provided crops. Photosphere could let the user mark "this is Rex" and cluster from there.

**Audit & sources**:
- "iNaturalist's CV model identifies 10,000+ species and adds new ones every ~1.7 hours" — [UNVERIFIED specific numbers]. The "iNaturalist Computer Vision Demo" link in the Sources footer ([inaturalist.org/pages/computer_vision_demo](https://www.inaturalist.org/pages/computer_vision_demo)) plausibly backs the species-count claim but I did not chase the URL to confirm "10,000+" or the "~1.7 hours" cadence. Treat both numbers as not-yet-verified.
- "Models are downloadable for offline use" (iNaturalist) — [UNVERIFIED]. Common claim about iNaturalist but I did not confirm offline-model availability and licensing.
- "PetFace, dog-face embedding models" — name-dropped. Existence not verified in this pass.
- "Pl@ntNet" — well-known plant-identification project; not specifically verified here.

### 1.3 Plant, Bird, Insect Identification
Extensions of the above using specialist models: Pl@ntNet, Merlin Bird ID, BugID. Useful for users with nature-heavy libraries (gardening, birdwatching, travel).

### 1.4 Location and Landmark Recognition
- **From EXIF GPS**: trivially extract lat/lon and reverse-geocode (Nominatim, Photon, Mapbox, MapTiler) to get country / city / suburb / point-of-interest names.
- **From image content** (no GPS): landmark classifiers (Google Landmarks v2 dataset has ~5M images of 200K landmarks). Useful for old scanned photos and stripped-EXIF images.
- **Geo-clustering**: group photos by trip / outing using DBSCAN on (timestamp, lat, lon).
- **Map view**: pin photos to a map, browse by region, draw a polygon to query.
- **"Where was this?"** for photos without GPS: ask a vision LLM (it is often surprisingly accurate from visual cues, as shown in the GEO-Detective research).

**Audit & sources**:
- "Nominatim, Photon, Mapbox, MapTiler" — all real reverse-geocoding services. Not individually verified in this audit.
- "Google Landmarks v2 dataset has ~5M images of 200K landmarks" — [UNVERIFIED specific numbers]. I did not chase a Google Landmarks v2 dataset URL.
- "GEO-Detective research" — [VERIFIED that the paper exists]: linked in the Sources footer as [arxiv.org/html/2511.22441](https://arxiv.org/html/2511.22441). The specific claim about vision LLMs being "surprisingly accurate from visual cues" relies on the paper; I did not read the paper to confirm the framing.
- "DBSCAN on (timestamp, lat, lon)" for geo-clustering — standard technique.

### 1.5 Named-Entity Recognition in Captions
Once captions or OCR text exist, run a small NER model to extract people, places, organizations and dates from the *text*, not the image. Useful for old scanned photos with handwritten captions on the back.

---

## 2. Search and Discovery

### 2.1 Semantic / Natural-Language Search ("smart search")
The single biggest user-visible AI win. Embed every photo with a vision-language model (CLIP, OpenCLIP, SigLIP, MetaCLIP) and embed user queries with the same model's text encoder. Nearest-neighbour search returns matching photos.

- Enables queries like "sunset at the beach", "kids opening presents", "red car in snow", "whiteboard with equations".
- Models: OpenAI CLIP (older, well-supported), OpenCLIP (more variants), SigLIP / SigLIP 2 (Google, stronger), MetaCLIP, EVA-CLIP.
- Multilingual variants exist (mCLIP, multilingual SigLIP) for non-English queries.
- Index storage: pgvector (Postgres), Qdrant, ChromaDB, sqlite-vec, LanceDB, FAISS. sqlite-vec is interesting for Photosphere because its data model is already file-based / per-collection.

**Audit & sources**:
- "OpenAI CLIP, OpenCLIP, SigLIP / SigLIP 2 (Google, stronger), MetaCLIP, EVA-CLIP" — model families exist. The "stronger" qualifier on SigLIP 2 is an editorial claim; [SigLIP 2 HF blog](https://huggingface.co/blog/siglip2) discusses improvements over SigLIP 1 but I did not benchmark against OpenAI CLIP here.
- "mCLIP, multilingual SigLIP" — multilingual SigLIP variants are documented in the [SigLIP 2 HF blog](https://huggingface.co/blog/siglip2).
- Vector stores list — all real products; not individually verified here. The Sources footer has comparison links ([4xxi vector DB comparison](https://4xxi.com/articles/vector-database-comparison/), etc.).

### 2.2 Image-to-Image Search
"Find more photos like this one" using the same CLIP embeddings. Variants:

- "More photos of this person" (face embedding).
- "More photos of this scene type".
- "More photos with this composition / colour palette".
- Crop-based search: select a region, find photos containing that thing.

### 2.3 Conversational Search (LLM over your photos)
Beyond keyword and semantic search, plug a chat LLM in front of the index so users can ask: "what did we do on our 2024 Japan trip?", "show me all photos with both kids and a beach", "did I take any photos at Alice's wedding?". Google calls this "Ask Photos"; it combines metadata, embeddings and an LLM.

Photosphere is already heading here via the in-progress **MCP server** (`packages/mcp-tools`, `apps/cli/src/cmd/mcp.ts`). With MCP, any LLM client (Claude Desktop, Claude Code, ChatGPT desktop, Cursor) becomes a chat interface to the photo library. This is arguably the *most leveraged* AI feature: instead of building a chat UI, you get every MCP-aware AI app for free.

**Audit & sources**:
- "Google calls this 'Ask Photos'; it combines metadata, embeddings and an LLM" — [VERIFIED that "Ask Photos" is a Google product]. The Sources footer links [TechCrunch on Google Photos AI features](https://techcrunch.com/2025/11/11/google-photos-adds-new-ai-features-for-editing-expands-ai-powered-search-to-over-100-countries/). The metadata-plus-embeddings-plus-LLM characterisation is my paraphrase, not a direct citation.
- "Photosphere ... in-progress MCP server (`packages/mcp-tools`, `apps/cli/src/cmd/mcp.ts`)" — [VERIFIED]: both paths exist in this repository.

### 2.4 Advanced Filters Powered by AI
- Filter by detected object class ("photos containing a dog and a bicycle").
- Filter by aesthetic / quality score.
- Filter by emotion / facial expression ("photos where Bob is smiling").
- Filter by indoor / outdoor, day / night, season, weather.
- Filter by dominant colour, composition (rule-of-thirds, symmetric), orientation.

---

## 3. Automatic Tagging and Captioning

### 3.1 Object and Scene Tagging
Per-photo multi-label classification: detect things present ("cake", "dog", "tree", "car", "guitar") and overall scene ("kitchen", "beach", "stadium"). Models: YOLOv8/v9/v10 for objects with bounding boxes, ResNet/EfficientNet trained on ImageNet/OpenImages for whole-image labels, Places365 for scenes.

### 3.2 Caption Generation
Generate a free-form sentence describing each photo. Used for accessibility, alternative search index, and as input to LLM-based search.

- **Specialist captioners**: BLIP-2, GIT, OFA, CoCa, Florence-2 (small and fast, very good quality).
- **Vision LLMs**: LLaVA, Llama 3.2 Vision (11B / 90B), Qwen2-VL, InternVL, MiniCPM-V, Pixtral, Moondream (very small, ~2B). PhotoPrism added Ollama integration for exactly this.
- Captions can be stored alongside metadata and re-indexed for keyword search, or fed to an embedder for richer semantic search than CLIP alone.

**Audit & sources**:
- "BLIP-2, GIT, OFA, CoCa, Florence-2 (small and fast, very good quality)" — all real captioning models. The "small and fast, very good quality" qualifier on Florence-2 is my characterisation; Florence-2 base ONNX is published at [onnx-community/Florence-2-base](https://huggingface.co/onnx-community/Florence-2-base) with 0.23 B parameters but I did not benchmark "very good quality" against alternatives.
- "LLaVA, Llama 3.2 Vision (11B / 90B), Qwen2-VL, InternVL, MiniCPM-V, Pixtral, Moondream (very small, ~2B)" — all real vision LLMs. Specific parameter counts (e.g. Moondream ~2B) are widely cited but not re-verified here.
- "PhotoPrism added Ollama integration for exactly this" — [VERIFIED]: [PhotoPrism Caption Generation docs](https://docs.photoprism.app/developer-guide/vision/caption-generation/) document the integration.

### 3.3 Auto-Albums and Smart Folders
Unsupervised clustering of embeddings into "albums" like "Vacations", "Birthdays", "Family Dinners", with auto-generated titles. K-Means / HDBSCAN on CLIP embeddings; LLM names each cluster from sampled captions.

### 3.4 OCR and Document Detection
Detect text *in* photos (street signs, menus, screenshots, receipts, whiteboards, book pages, handwritten notes). Adds the extracted text to the search index.

- Engines: Tesseract (classic), PaddleOCR, EasyOCR, Apple Vision (mobile), Google ML Kit (mobile), Microsoft TrOCR (handwriting), Mistral OCR (very strong, self-hostable), Surya.
- Side-feature: detect that a photo *is* a document (receipt, ID, whiteboard) and offer to perspective-correct + binarize it, like Apple's "Scan Document".
- Receipt parsing: layer Donut or LayoutLM on top for structured extraction.

**Audit & sources**:
- All OCR engines listed are real products. The "very strong, self-hostable" qualifier on Mistral OCR is editorial; Mistral OCR is referenced in the Sources footer ([mistral.ai/news/mistral-ocr](https://mistral.ai/news/mistral-ocr)).
- "Donut or LayoutLM" for receipt parsing — both are real models in the document-AI space; not individually verified.

---

## 4. Quality, Curation and Cleanup

These are some of the most-loved features in commercial apps because they reduce visible library clutter.

### 4.1 Duplicate and Near-Duplicate Detection
- **Exact** duplicates: cryptographic hash (SHA-256) of file contents. Already cheap.
- **Visually identical** duplicates (re-encoded, resized, watermarked): perceptual hashes - aHash, dHash, pHash, wHash, BlockHash.
- **Near-duplicates** (burst shots, slight crop, edited version): CNN or CLIP embedding similarity above a threshold.
- Present results as groups; let the user keep one or all.

### 4.2 Best-of-Burst Selection
When the camera fired 10 shots in 2 seconds, automatically suggest the best one. Combines:

- Sharpness / blur detection (Laplacian variance, NIMA).
- Eye-open / smile detection on faces (especially important for group photos).
- Aesthetic score (NIMA, MUSIQ, CLIP-IQA, Q-Align).
- Composition score.

### 4.3 Aesthetic and Technical Quality Scoring
Rate each photo on technical quality (sharpness, exposure, noise) and aesthetic quality (composition, lighting). Models: NIMA, MUSIQ, MANIQA, CLIP-IQA. Drives best-photo selection, auto-album cover picking, and "show me my best photos of the year".

### 4.4 Junk Detection
Auto-flag photos that are almost certainly not worth keeping: heavily blurred, completely dark / completely white, accidental shots, screenshots of memes, screenshots of receipts already OCR'd. Let the user batch-review and delete.

### 4.5 Content Moderation / NSFW Flagging
Optional safety filter for shared libraries, kid accounts, or family browsing modes. Open-source models: NudeNet, Falconsai/nsfw_image_detection, GantMan/nsfw_model. Should always be opt-in and local.

### 4.6 Privacy / Sensitive-Content Detection
Detect things the user might not want shown in slideshows or shared: faces of children, screenshots of bank statements, photos of IDs / passports / credit cards, photos of medical conditions. Hide from random "Memories" surfaces by default.

**Audit & sources for section 4**:
- "aHash, dHash, pHash, wHash, BlockHash" — standard perceptual-hash families; Sources footer references [Ben Hoyt's article on perceptual hashing](https://benhoyt.com/writings/duplicate-image-detection/) and [MDPI comparison paper](https://www.mdpi.com/2079-9292/15/7/1493).
- "NIMA, MUSIQ, MANIQA, CLIP-IQA, Q-Align" — real aesthetic-quality model families; individual citations not in this doc.
- "Laplacian variance" for sharpness — standard technique (Pech-Pacheco et al. 2000); not specifically cited.
- "NudeNet, Falconsai/nsfw_image_detection, GantMan/nsfw_model" — real NSFW models; [Falconsai/nsfw_image_detection on HF](https://huggingface.co/Falconsai/nsfw_image_detection) is in the Sources footer.

---

## 5. Editing and Enhancement

### 5.1 Super-Resolution and Restoration
- **Upscaling**: Real-ESRGAN, SwinIR, HAT, BSRGAN. Bring 480p phone snaps from 2008 to 4K.
- **Face restoration**: GFPGAN, CodeFormer, restore-old-photos pipelines.
- **Denoising**: NAFNet, Restormer.
- **Scratch / damage removal** for scanned old photos: Bringing-Old-Photos-Back-to-Life (Microsoft).
- **Deblurring**: MPRNet, NAFNet.

### 5.2 Subject Cutout and Background Replacement
Models: rembg (U²-Net), BiRefNet, SAM (Segment Anything) / SAM 2. Enables one-click background removal, "remove this person from the background", green-screen-style replacements.

### 5.3 Object Removal / Inpainting
Pick a region, AI fills it in. Models: LaMa, MAT, PowerPaint, SDXL-inpainting, Flux-fill. Apple's "Clean Up" and Google's "Magic Eraser" are the reference UX.

### 5.4 Generative Editing
Text-prompted edits ("make the sky sunset", "add a hat"). Models: Stable Diffusion + ControlNet, SDXL, Flux Kontext, Qwen-Image-Edit. Heavier dependency, more controversial (raises authenticity questions), so probably opt-in.

### 5.5 Colourization
Black-and-white photo colourization. Models: DeOldify (classic), ColorMNet, BigColor.

### 5.6 Auto-Enhance
One-click white-balance, exposure, contrast, and saturation correction driven by a learned model rather than fixed heuristics. Compose with NIMA to validate the result is actually better.

**Audit & sources for section 5**:
- All model names (Real-ESRGAN, SwinIR, HAT, BSRGAN, GFPGAN, CodeFormer, NAFNet, Restormer, MPRNet, Bringing-Old-Photos-Back-to-Life, rembg/U²-Net, BiRefNet, SAM/SAM 2, LaMa, MAT, PowerPaint, SDXL-inpainting, Flux-fill, Stable Diffusion, ControlNet, SDXL, Flux Kontext, Qwen-Image-Edit, DeOldify, ColorMNet, BigColor) are real published models. Specific quality comparisons and "reference UX" claims (Apple's "Clean Up", Google's "Magic Eraser") are editorial paraphrase, not cited per-line. The Sources footer links [Real-ESRGAN explained](https://upscalefree.app/blog/real-esrgan-explained/).

---

## 6. Video Features

Videos are usually the second-class citizens of photo apps. AI changes that.

### 6.1 Scene / Shot Detection
Split a long video into shots. Library: PySceneDetect. Foundation for thumbnails, summaries, and frame-level embeddings.

### 6.2 Frame Sampling and Indexing
Sample key frames, run CLIP/captioning/face recognition on each, treat the video as searchable like photos. Enables "videos containing Alice at the beach".

### 6.3 Auto-Highlight Clips
Identify the most interesting N seconds of a long video. Combines action recognition (humans doing something), audio energy, face detection (people in shot), aesthetic scoring. Used by Google Photos / Apple Memories for auto-generated slideshow videos.

### 6.4 Speech-to-Text
Transcribe audio in videos with Whisper / faster-whisper / Distil-Whisper / WhisperX. Captions become searchable text and can drive video chapters.

### 6.5 Action and Activity Recognition
"Surfing", "kid blowing out candles", "dog catching frisbee". Models: VideoMAE, X-CLIP, TimeSformer, ViViT. More compute-intensive; could be opt-in for power users.

**Audit & sources for section 6**:
- PySceneDetect, Whisper / faster-whisper / Distil-Whisper / WhisperX, VideoMAE, X-CLIP, TimeSformer, ViViT — all real projects/models. The "Google Photos / Apple Memories for auto-generated slideshow videos" attribution for highlight-clip technique is editorial.
- Sources footer has [Nature paper on AI-driven video summarization](https://www.nature.com/articles/s41598-025-87824-9) and a Toolify summary, neither of which I directly verified.

---

## 7. Memories, Stories and Sharing

Engagement features that surface old content using the underlying AI signals above.

- **"On this day" / "X years ago today"**: pure date math, but use aesthetic and face scores to pick the *best* photo from that day.
- **Auto-generated story videos** ("Your 2024 Year in Review", "Trip to Italy"): cluster by time+location+people, score frames, ken-burns the best, add music.
- **Theme collections**: "Photos of Alice over the years", "Every sunset you've shot", "Your dog growing up", "Whiteboards from work".
- **Trip detection**: cluster photos that are away from home cluster + within a date window, auto-suggest "Create album: Trip to Tokyo 2024".
- **Suggested sharing**: "You took 30 photos with Bob on Saturday, share with him?".

**Audit & sources for section 7**:
- Section 7 is design ideas, not factual claims. Where it references Google Photos / Apple Memories as inspiration, those are widely-known products, not individually verified.

---

## 8. AI Agent / Chat Integration (MCP)

Photosphere already has an in-progress MCP server. This is a significant leverage point and worth calling out as its own category.

Possible MCP tools to expose to a chat LLM:

- `search(query)`, `search_by_face(person)`, `search_by_location(place)`, `search_by_date(range)`.
- `get_photo(id)`, `get_metadata(id)`, `get_thumbnail(id)`.
- `tag_photos(ids, tags)`, `add_to_album(ids, album)`, `rate(ids, rating)`.
- `find_duplicates(threshold)`, `find_similar(id)`, `describe(id)`.
- `summarize_day(date)`, `summarize_trip(start, end)`.
- `export(query, dest)`, `slideshow(query)`.

With these primitives, any MCP-aware client (Claude Desktop, Claude Code, ChatGPT, Cursor, Gemini CLI, etc.) becomes a free chat-with-your-photos interface. The user types natural-language requests; the LLM decomposes them into MCP calls; Photosphere does the work.

This generalises further into a **photo-library agent**: the LLM can be given a goal like "go through last year's photos, find the ones I might want to print, group them by event, and propose a photobook outline" and execute multi-step plans.

**Audit & sources for section 8**:
- "MCP-aware client (Claude Desktop, Claude Code, ChatGPT, Cursor, Gemini CLI, etc.)" — these clients exist and several support MCP, though MCP support varies and evolves. Not individually verified here. Sources footer references three MCP integrations ([Google Photos MCP Server](https://mcpservers.org/servers/savethepolarbears/google-photos-mcp), [Composio Googlephotos toolkit](https://composio.dev/toolkits/googlephotos), [Image Analysis MCP Server](https://glama.ai/mcp/servers/@champierre/image-mcp-server)).
- The proposed tool list is *design proposal*, not a description of existing tools.

---

## 9. Per-Surface Recommendations

### 9.1 Electron Desktop App

Strongest fit, because the desktop has compute (CPU, GPU, NPU on newer machines) and storage. Recommended priority order:

1. **Face detection + recognition + named clusters** (biggest UX win, well-understood).
2. **CLIP-based semantic search** (transformative once it works).
3. **Object / scene tagging + OCR** (feeds search; cheap to add once ML pipeline exists).
4. **Duplicate / near-duplicate detection** (immediate library hygiene).
5. **Location recognition + map view** (mostly free given EXIF GPS).
6. **Caption generation via local vision LLM** (Ollama integration, like PhotoPrism).
7. **Animal / plant / landmark recognition** (specialist models, easy to bolt on).
8. **Aesthetic scoring + best-of-burst** (drives memories / sharing).
9. **Restoration / upscaling / inpainting** (heavy, opt-in, but high "wow" value).
10. **Memory videos / story generation** (depends on most of the above being in place).

Hardware acceleration paths: ONNX Runtime with CUDA / DirectML / CoreML / OpenVINO, CTranslate2, PyTorch, llama.cpp, Ollama.

### 9.2 CLI Tool

CLI is the natural home for *batch* AI work that the GUI shouldn't block on:

- **Backfill index**: walk an existing library, run face detection / CLIP / OCR / captioning / quality scoring on every photo and store results.
- **Bulk import enrichment**: process every new photo on ingest.
- **Re-index after model upgrade**: when you swap CLIP-B for CLIP-L, re-embed everything.
- **Headless scheduled jobs**: nightly duplicate detection, weekly NSFW sweep, etc., suitable for cron on a NAS.
- **Pipeable AI commands**: `photosphere search "sunset" | photosphere export --to /tmp/sunsets`.
- **Model management**: download, pin, switch, delete models. Show disk + RAM cost.
- **MCP server entry point**: which already exists. The CLI is naturally where the MCP server is exposed since the agent needs no GUI.

### 9.3 Mobile App (future)

Mobile constraints are different: limited compute, limited battery, limited storage, but excellent on-device acceleration (Neural Engine on iOS, NNAPI / Gemini Nano / NPUs on Android). Apple Photos runs all of its face / scene / OCR locally.

Realistic options:

- **Small models on-device** for: face detection (MediaPipe, Apple Vision), OCR (Apple Vision, Google ML Kit), object detection (YOLOv8n, MobileNet), CLIP variants (MobileCLIP, TinyCLIP), scene classification. Runtimes: Core ML, TensorFlow Lite, ONNX Runtime Mobile, ExecuTorch.
- **Heavy work delegated to the desktop server** over LAN: full CLIP indexing, vision LLM captioning, restoration, video processing. Mobile just renders results.
- **Capture-time AI**: classify photos as they are taken, scan business cards / receipts on capture, suggest sharing right after the shutter.
- **On-device search index** of just the user's recent / favourite subset, so search works offline.
- **MCP / chat client on phone**: the mobile app could host a chat panel that talks to the desktop MCP server when on the same network.

**Audit & sources for section 9**:
- "Apple Photos runs all of its face / scene / OCR locally" — widely-stated but not specifically cited here. Apple Vision and Core ML are real frameworks.
- Hardware acceleration paths (ONNX Runtime CUDA/DirectML/CoreML/OpenVINO, CTranslate2, PyTorch, llama.cpp, Ollama) — all real runtimes; specific Photosphere-acceleration claims are aspirational.
- Mobile model names (MediaPipe, Apple Vision, Google ML Kit, YOLOv8n, MobileNet, MobileCLIP, TinyCLIP, Core ML, TensorFlow Lite, ONNX Runtime Mobile, ExecuTorch) — all real; not individually re-verified.

---

## 10. Privacy, Trust and Control

Cross-cutting concerns that any AI feature in a self-hosted product needs to address up front.

- **Local-first by default**: every feature in this doc has a local-only option. That is the whole point of a self-hosted product vs. Google Photos.
- **Optional cloud / API fallback**: power users with a Claude / OpenAI / Gemini API key may want larger-model captions or "Ask Photos" using a frontier model. Allow opt-in, never exfiltrate by default.
- **Per-feature opt-in / opt-out**: face recognition, NSFW, sensitive-content detection, generative editing are all features users may want disabled.
- **Transparency**: show what the AI inferred, with confidence, and let the user correct it. Wrong tags / wrong face matches must be one-click fixable, and corrections should feed back into the model (re-cluster, retrain a personal classifier).
- **Auditability**: log which model produced which tag at what version, so a model upgrade can re-derive only what changed.
- **Data minimisation**: don't store raw face crops or full embeddings forever if not needed; allow user to purge AI-derived data without losing originals.
- **Model provenance**: pin model versions and document licences, especially for distributed builds (CLIP is MIT, InsightFace is non-commercial for some weights, NudeNet is MIT, Llama 3.2 is custom Meta licence).
- **Children's faces**: extra care. Apple intentionally treats child faces conservatively in Memories; worth matching.
- **Authenticity flag**: if a photo has been generatively edited, mark it. Comply with emerging C2PA standards.

**Audit & sources for section 10**:
- "CLIP is MIT, InsightFace is non-commercial for some weights, NudeNet is MIT, Llama 3.2 is custom Meta licence" — [PARTIALLY UNVERIFIED specifics]. Each project does have a licence but I have not re-confirmed the specific licence per project as part of this audit. Treat as "check the licences before shipping" guidance.
- "Apple intentionally treats child faces conservatively in Memories" — widely-stated practitioner claim, not specifically cited.
- "C2PA standards" — real standards body ([c2pa.org](https://c2pa.org/)); the "emerging" qualifier is editorial.

---

## 11. What Competitors Ship Today (Reference Points)

For sanity-checking scope.

**Immich** (closest open-source comparator):
- CLIP-based smart search (multilingual variants supported).
- InsightFace-based face detection + recognition + named clusters.
- OCR.
- Duplicate detection.
- Auto-generated "Memories" by date.
- All ML runs in a separate Docker container, GPU-accelerated, can run on a different host.

**PhotoPrism**:
- ONNX SCRFD face detector (April 2026 update).
- Object / scene / colour classifiers (TensorFlow).
- Ollama integration for LLM-based captions and labels.
- Strong metadata editing.

**Google Photos**:
- Face / pet recognition.
- Natural-language search.
- "Ask Photos" conversational search (Gemini).
- Magic Editor / Magic Eraser / Reimagine.
- Auto-Memories / Highlight reels with music.
- AI-generated templates and reels.

**Apple Photos**:
- All-local face / scene / OCR via Neural Engine.
- Memories with auto-music.
- Clean Up (object removal).
- People & Pets album.
- Visual Look Up (identify plants, animals, landmarks, art).

The implication: most of the AI features users now expect from "a photo app" are deliverable on-device with open-source models. The differentiator for Photosphere is *local-first + agent-accessible (MCP) + cross-platform*, which none of the above combine.

**Audit & sources for section 11**:
- Immich features list — partially verified:
  - CLIP smart search: documented in [Immich Smart Search blog](https://pixelunion.eu/blog/2026/04/immich-smart-search/) (Sources footer).
  - InsightFace face recognition: documented at [Immich Facial Recognition docs](https://docs.immich.app/features/facial-recognition/) and [immich-app/buffalo_l](https://huggingface.co/immich-app/buffalo_l).
  - OCR, duplicate detection, Memories — not individually verified in this audit pass.
- PhotoPrism features list — partially verified:
  - "ONNX SCRFD face detector (April 2026 update)": SCRFD via ONNX is documented at [PhotoPrism face recognition docs](https://docs.photoprism.app/developer-guide/vision/face-recognition/); the specific "April 2026" date appears in search snippets but I did not open release notes.
  - Ollama integration: [PhotoPrism Caption Generation docs](https://docs.photoprism.app/developer-guide/vision/caption-generation/).
- Google Photos and Apple Photos feature lists — high-level summaries of well-known products. Not individually cited.
- "None of the above combine local-first + agent-accessible (MCP) + cross-platform" — editorial conclusion, not strictly verifiable; the underlying claim is plausible based on these products' public positioning.

---

## Sources

### Self-hosted photo managers
- [Immich vs PhotoPrism comparison (elest.io)](https://blog.elest.io/immich-vs-photoprism-which-self-hosted-photo-manager-for-your-family/)
- [Immich Facial Recognition docs](https://docs.immich.app/features/facial-recognition/)
- [Immich Smart Search (PixelUnion)](https://pixelunion.eu/blog/2026/04/immich-smart-search/)
- [Immich Architecture](https://docs.immich.app/developer/architecture/)
- [Immich Hardware Acceleration](https://docs.immich.app/features/ml-hardware-acceleration/)
- [Immich Searching docs](https://docs.immich.app/features/searching/)
- [PhotoPrism Face Recognition](https://docs.photoprism.app/developer-guide/vision/face-recognition/)
- [PhotoPrism Features](https://www.photoprism.app/features)
- [Best Self-Hosted Photo Management 2026](https://selfhosting.sh/best/photo-management/)

### Semantic search and CLIP
- [Inside the AI Photo Gallery: How CLIP Powers Vision (Veroke)](https://www.veroke.com/insights/inside-the-ai-photo-gallery-how-clip-powers-advanced-vision-solutions/)
- [How Offline AI Photo Search Works (photochat-ai)](https://photochat-ai.com/offline-ai-photo-search.html)
- [Semantic Image Search with CLIP and FAISS (Ultralytics)](https://docs.ultralytics.com/guides/similarity-search/)
- [CLIP: Connecting text and images (OpenAI)](https://openai.com/index/clip/)
- [Building an Image Similarity Search Engine with FAISS and CLIP](https://towardsdatascience.com/building-an-image-similarity-search-engine-with-faiss-and-clip-2211126d08fa/)

### Commercial photo apps
- [Google Photos new AI features 2025 (TechCrunch)](https://techcrunch.com/2025/11/11/google-photos-adds-new-ai-features-for-editing-expands-ai-powered-search-to-over-100-countries/)
- [Apple Photos vs Google Photos comparison](https://www.macobserver.com/tips/round-ups/apple-photos-vs-google-photos-cloud-library-comparison/)
- [Best AI Photo Organizers 2026 (Unite.AI)](https://www.unite.ai/best-ai-powered-photo-organizers/)
- [Best AI Photo Organizers (PhotoWorkout)](https://www.photoworkout.com/best-ai-photo-organizer/)

### Local vision LLMs and captioning
- [Llama 3.2 Vision (Ollama)](https://ollama.com/library/llama3.2-vision)
- [llama-vision-image-tagger (GitHub)](https://github.com/Troyanovsky/llama-vision-image-tagger)
- [Local AI vision for your photos (Medium)](https://medium.com/design-bootcamp/local-ai-vision-for-your-photos-build-ai-image-tagger-with-llama-vision-and-chromadb-e3b1e0eeac43)
- [Llama 3.2-Vision deploy (Modular)](https://docs.modular.com/stable/max/tutorials/deploy-llama-vision/)

### Object, landmark, species recognition
- [YOLO Object Detection (Ultralytics)](https://docs.ultralytics.com/tasks/detect)
- [YOLO-based landmark recognition](https://www.researchgate.net/publication/377463910_YOLO-based_landmark_recognition_system)
- [GEO-Detective: location privacy risks via LLM](https://arxiv.org/html/2511.22441)
- [iNaturalist Computer Vision Demo](https://www.inaturalist.org/pages/computer_vision_demo)
- [AI App Identifies Plants and Animals (NVIDIA)](https://developer.nvidia.com/blog/ai-app-identifies-plants-and-animals-in-seconds/)
- [Race to Identify Every Species (Smithsonian)](https://www.smithsonianmag.com/innovation/the-race-to-develop-artificial-intelligence-that-can-identify-every-species-on-the-planet-180982732/)

### Duplicates and quality
- [Duplicate image detection with perceptual hashing (Ben Hoyt)](https://benhoyt.com/writings/duplicate-image-detection/)
- [Effective near-duplicate detection (ScienceDirect)](https://www.sciencedirect.com/science/article/abs/pii/S0306457325000287)
- [Perceptual Hashing vs Deep Embeddings (MDPI)](https://www.mdpi.com/2079-9292/15/7/1493)
- [Detect Duplicate Photos guide](https://www.aiimagedetector.com/blog/detect-duplicate-photos)

### OCR
- [Mistral OCR](https://mistral.ai/news/mistral-ocr)
- [Microsoft Azure OCR overview](https://learn.microsoft.com/en-us/azure/ai-services/computer-vision/overview-ocr)
- [Google Cloud Vision OCR](https://docs.cloud.google.com/vision/docs/ocr)
- [Transkribus for historical handwriting](https://www.transkribus.org/)

### Video AI
- [Video Summarization techniques (Toolify)](https://www.toolify.ai/ai-news/video-summarization-human-detection-and-activity-recognition-3410299)
- [AI-driven video summarization (Nature)](https://www.nature.com/articles/s41598-025-87824-9)

### Curation and memories
- [Automatic Curation of Photo Memories (Storyo)](https://medium.com/storyo/automatic-curation-of-photo-memories-through-unsupervised-learning-53cc985aa7ac)
- [Stop Photo Clutter: 7 Ways AI Organizes Your Memories](https://www.taskfoundry.com/2025/07/ai-photo-organization-guide.html)
- [Google Photos AI video highlights (ChromeUnboxed)](https://chromeunboxed.com/google-photos-ai-video-highlights-tool/)

### Image restoration and editing
- [Real-ESRGAN Explained](https://upscalefree.app/blog/real-esrgan-explained/)
- [Real-ESRGAN on Replicate](https://replicate.com/nightmareai/real-esrgan)

### Vector databases
- [Vector Database Comparison 2026 (4xxi)](https://4xxi.com/articles/vector-database-comparison/)
- [Best Vector Databases 2026 (Firecrawl)](https://www.firecrawl.dev/blog/best-vector-databases)
- [Pgvector vs Qdrant (Tiger Data)](https://www.tigerdata.com/blog/pgvector-vs-qdrant)

### Mobile on-device AI
- [Awesome Mobile AI (GitHub)](https://github.com/umitkacar/awesome-mobile-ai)
- [On-Device ML: Core ML vs TFLite 2026](https://www.whistl.app/on-device-ml-core-ml-tensorflow-lite-2026.html)
- [Building AI-Powered Mobile Apps (Medium)](https://medium.com/@DigiAuxilio/how-to-build-ai-powered-mobile-apps-using-on-device-machine-learning-core-ml-tensorflow-lite-c44ceab032d5)
- [Best AI SDKs for On-Device Inference 2026 (RunAnywhere)](https://www.runanywhere.ai/blog/best-ai-sdks-on-device-inference-2026)

### NSFW and moderation
- [Falconsai/nsfw_image_detection (Hugging Face)](https://huggingface.co/Falconsai/nsfw_image_detection)
- [VModA: Adaptive NSFW Image Moderation (arXiv)](https://arxiv.org/pdf/2505.23386)

### MCP and agent integration
- [Google Photos MCP Server](https://mcpservers.org/servers/savethepolarbears/google-photos-mcp)
- [Googlephotos MCP Integration (Composio)](https://composio.dev/toolkits/googlephotos)
- [Image Analysis MCP Server](https://glama.ai/mcp/servers/@champierre/image-mcp-server)
