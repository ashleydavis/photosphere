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
import { getDatabaseSummaryHandler } from "node-api/src/lib/get-database-summary.worker";
import { prefetchDatabaseHandler } from "node-api/src/lib/prefetch-database.worker";
import { verifyFileHandler } from "node-api/src/lib/verify.worker";
import { checkFileHandler } from "node-api/src/lib/check.worker";
import { receiveShareHandler, findReceiverHandler, sendPayloadHandler } from "node-api/src/lib/lan-share.worker";
import { checkDatabaseExistsHandler } from "node-api/src/lib/check-database-exists.worker";
import { syncDatabaseHandler } from "node-api/src/lib/sync-database.worker";
import { listS3DirsHandler } from "node-api/src/lib/list-s3-dirs.worker";
import { readDatabasesConfigHandler, writeDatabasesConfigHandler } from "node-api/src/lib/databases-config.worker";
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

// Register the get-database-summary handler: the /database-summary page dispatches this task to
// compute the summary of the open database (photo/file counts, total size, integrity hashes).
registerHandler("get-database-summary", getDatabaseSummaryHandler);

// Register the prefetch-database handler: load-assets fire-and-forget queues this for a partial
// database to pull the missing thumbnails and BSON database files from origin storage.
registerHandler("prefetch-database", prefetchDatabaseHandler);

// Register the verify-file / check-file handlers for parity with the desktop registry
// (packages/node-api/src/lib/task-handlers.ts). Nothing on mobile queues them yet: their only
// callers are the CLI verify and check commands.
registerHandler("verify-file", verifyFileHandler);
registerHandler("check-file", checkFileHandler);

// Register the real shared LAN-share handlers (the same ones desktop/CLI use). They run unchanged in
// the embedded engine because the bundle aliases dgram/tls/https/crypto to native-backed shims, so
// discovery and the cert-pinned HTTPS transfer work on device.
registerHandler("receive-share", receiveShareHandler);
registerHandler("find-receiver", findReceiverHandler);
registerHandler("send-payload", sendPayloadHandler);

// Register the check-database-exists handler: probes whether an accessible database lives at a path
// (via node-api's checkConnectivity). Desktop registers the same handler through initTaskHandlers, so
// the shared openDatabase guard runs the identical check on both platforms.
registerHandler("check-database-exists", checkDatabaseExistsHandler);

// Register the sync-database handler: syncs a local database against its configured (e.g. S3) origin.
// It opens the origin via storage (S3 over the mobile worker's S3 client) and streams sync-started /
// sync-batch / sync-completed messages back to the provider's scheduler and UI.
registerHandler("sync-database", syncDatabaseHandler);

// Register the list-s3-dirs handler: lists directories under an S3 bucket/prefix using the S3 client
// and the keychain-backed credentials, so the WebView's S3 browser lists a real bucket rather than
// rendering the empty-array stub.
registerHandler("list-s3-dirs", listS3DirsHandler);

// Register the databases.toml handlers: the app's database list and recents live in the same TOML
// file desktop uses, in the storage sandbox. The WebView has no filesystem access, so these are how
// the config is read and written.
registerHandler("read-databases-config", readDatabasesConfigHandler);
registerHandler("write-databases-config", writeDatabasesConfigHandler);

// Expose the worker entry point (globalThis.__photosphereWorker = { runTask }).
installWorkerGlobal();
