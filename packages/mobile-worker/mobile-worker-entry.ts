import { registerHandler } from "task-queue";
import { helloWorldHandler } from "./src/lib/hello-world-handler";
import { installWorkerGlobal } from "./src/index";

//
// Embedded worker entry point. This module is bundled into `worker.bundle.js`
// and evaluated once inside each mobile JS engine instance. It registers the task
// handlers and exposes `globalThis.__photosphereWorker.runTask` so native code can
// dispatch tasks into the engine.
//
// The real Node.js-using handlers (`initTaskHandlers()` from `node-api`) are not
// registered here yet because they import Node built-ins the browser bundle target
// cannot resolve; they are added once the native Node/`fs` seam exists. The
// `hello-world` handler uses no Node APIs, so it runs end to end in the engine today.
//

// Register the Hello World demonstrator handler.
registerHandler("hello-world", helloWorldHandler);

// Expose the worker entry point (globalThis.__photosphereWorker = { runTask }).
installWorkerGlobal();
