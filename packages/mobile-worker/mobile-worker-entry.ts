// Install Buffer/process globals BEFORE any storage/database module evaluates (import order matters:
// bson selects its byte-utils based on globalThis.Buffer at import time).
import "./src/lib/install-globals";

import { registerHandler } from "task-queue";
import { loadAssetsHandler } from "node-api/src/lib/load-assets.worker";
import { createDatabaseHandler } from "node-api/src/lib/create-database.worker";
import { replicateDatabaseHandler } from "node-api/src/lib/replicate-database.worker";
import { moveAssetsHandler } from "node-api/src/lib/move-assets.worker";
import { saveAssetHandler } from "node-api/src/lib/save-asset.worker";
import { saveAssetsBatchHandler } from "node-api/src/lib/save-assets-batch.worker";
import { assetServerHandler } from "node-api/src/lib/asset-server.worker";
import { importAssetsHandler } from "node-api/src/lib/import-assets.worker";
import { hashFileHandler } from "node-api/src/lib/hash-file.worker";
import { uploadAssetHandler } from "node-api/src/lib/upload-asset.worker";
import { receiveShareHandler, findReceiverHandler, sendPayloadHandler } from "node-api/src/lib/lan-share.worker";
import { installWorkerGlobal } from "./src/index";

//
// Embedded worker entry point. This module is bundled into `worker.bundle.js`
// and evaluated once inside each mobile JS engine instance. It registers the task
// handlers and exposes `globalThis.__photosphereWorker.runTask` so native code can
// dispatch tasks into the engine.
//
// The build (see bundle.ts) redirects Node built-ins (`fs`, `path`, `os`, `stream`,
// `crypto`, `child_process`) to the mobile shims in `src/shims`, and redirects the native-only
// packages (`@aws-sdk/*`, `vault`, `tools`) that the load-assets module graph imports but the
// read path never calls. This lets the real `load-assets` handler run unchanged: it reads the
// database through `FileStorage` over the native `host.fs*` functions.
//

// Register the real load-assets handler: it opens a database via storage (native-backed fs) and
// streams asset pages back to the gallery.
registerHandler("load-assets", loadAssetsHandler);

// Register the create-database handler: initializes a new empty database on device storage.
registerHandler("create-database", createDatabaseHandler);

// Register the replicate-database handler: copies a source database to a destination path.
registerHandler("replicate-database", replicateDatabaseHandler);

// Register the move-assets handler: moves assets from one database to another.
registerHandler("move-assets", moveAssetsHandler);

// Register the save-asset / save-assets-batch handlers: export asset files to a chosen destination.
registerHandler("save-asset", saveAssetHandler);
registerHandler("save-assets-batch", saveAssetsBatchHandler);

// Register the long-running asset-server handler: stands up the express asset server over the
// shimmed http/net (backed by the native TCP host functions) so the WebView loads assets over a
// real localhost socket, exactly like desktop.
registerHandler("asset-server", assetServerHandler);

// Register the import handlers. import-assets is the orchestrator: it scans the picked files and
// spawns hash-file / upload-asset subtasks, which are queued back on the native engine pool (the
// mobile main-thread queue) and run on other engine slots, exactly like desktop/CLI.
registerHandler("import-assets", importAssetsHandler);
registerHandler("hash-file", hashFileHandler);
registerHandler("upload-asset", uploadAssetHandler);

// Register the real shared LAN-share handlers (the same ones desktop/CLI use). They run unchanged in
// the embedded engine because the bundle aliases dgram/tls/https/crypto to native-backed shims, so
// discovery and the cert-pinned HTTPS transfer work on device.
registerHandler("receive-share", receiveShareHandler);
registerHandler("find-receiver", findReceiverHandler);
registerHandler("send-payload", sendPayloadHandler);

// Expose the worker entry point (globalThis.__photosphereWorker = { runTask }).
installWorkerGlobal();
