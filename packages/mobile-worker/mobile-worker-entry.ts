// Install Buffer/process globals BEFORE any storage/database module evaluates (import order matters:
// bson selects its byte-utils based on globalThis.Buffer at import time).
import "./src/lib/install-globals";

// Then the WHATWG URL globals the AWS SDK builds every request URL through. Imported second because
// whatwg-url's dependency tree reads TextEncoder at module-init time, which install-globals provides.
import "./src/lib/install-url";

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
import { getImportRecordHandler } from "node-api/src/lib/get-import-record.worker";
import { prefetchDatabaseHandler } from "node-api/src/lib/prefetch-database.worker";
import { verifyFileHandler } from "node-api/src/lib/verify.worker";
import { checkFileHandler } from "node-api/src/lib/check.worker";
import { receiveShareHandler, findReceiverHandler, sendPayloadHandler } from "node-api/src/lib/lan-share.worker";
import { checkDatabaseExistsHandler } from "node-api/src/lib/check-database-exists.worker";
import { syncDatabaseHandler } from "node-api/src/lib/sync-database.worker";
import { listS3DirsHandler } from "node-api/src/lib/list-s3-dirs.worker";
import { readDatabasesConfigHandler, writeDatabasesConfigHandler } from "node-api/src/lib/databases-config.worker";
import { readAutoImportConfigHandler, writeAutoImportConfigHandler } from "node-api/src/lib/auto-import-config.worker";
import { planAutoImportHandler } from "./src/lib/plan-auto-import.worker";
import { recordDefaultDatabaseHandler } from "./src/lib/record-default-database.worker";
import { evictOriginalsHandler } from "node-api/src/lib/evict-originals.worker";
import { cleanupSourcesHandler } from "node-api/src/lib/cleanup-sources.worker";
import { registerMediaSourceBuilder } from "node-api/src/lib/media-source-registry";
import { IDeviceAlbumAutoImportSource } from "api/src/lib/auto-import-settings";
import { DeviceMediaSource } from "./src/lib/device-media-source";
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
registerHandler("get-import-record", getImportRecordHandler);

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
// (via node-api's checkDatabaseExists). Desktop registers the same handler through initTaskHandlers, so
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

// Register the auto-import.toml handlers: the automatic import settings live in a file in the
// storage sandbox rather than in the WebView's localStorage, because the background import runs
// while the app is off screen and has to be able to read them.
registerHandler("read-auto-import-config", readAutoImportConfigHandler);
registerHandler("write-auto-import-config", writeAutoImportConfigHandler);

// Register the background import's two decisions. plan-auto-import says whether a pass should run,
// what it imports into and what it watches; record-default-database records a database the pass has
// just created, so the next pass does not create it again. Both are asked for by the native
// background import (the Android foreground service, the iOS driver), which must not parse or write
// these files itself: the format is defined once, here, in TypeScript.
registerHandler("plan-auto-import", planAutoImportHandler);
registerHandler("record-default-database", recordDefaultDatabaseHandler);

// Register the device photo library as a media source. The automatic import scanner only ever talks
// to the IMediaSource interface, so registering this here is what lets the same import task that
// watches folders on desktop watch the photo library on a phone, with nothing in the task itself
// knowing the difference.
registerMediaSourceBuilder("device-album", (sources, options) => {
    return new DeviceMediaSource(sources as IDeviceAlbumAutoImportSource[]);
});

// The eviction handler: the same task the desktop app runs.
//
// Automatic import is an `import-assets` task like any other, registered above. It holds one engine
// slot for as long as the setting is on, and the hash-file and upload-asset tasks it queues hold
// more, capped at MOBILE_MAX_CONCURRENT_CHILD_TASKS. EnginePool.POOL_SIZE is sized for that whole
// chain with room to spare. Shrinking it deadlocks automatic import, and the failure is silent: the
// setting stays on, the task stays running, and the counts stay at zero.
registerHandler("evict-originals", evictOriginalsHandler);
registerHandler("cleanup-sources", cleanupSourcesHandler);

// Expose the worker entry point (globalThis.__photosphereWorker = { runTask }).
installWorkerGlobal();
