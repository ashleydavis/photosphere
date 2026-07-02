import express from "express";
import { createServer } from "http";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { createAssetServerCore } from "./asset-server-core";
import { attachAssetServerRoutes } from "./asset-server-routes";

//
// Input data for the long-running asset-server task.
//
export interface IAssetServerTaskData {
    //
    // Port to bind. 0 or omitted lets the OS assign a free loopback port.
    //
    port?: number;
}

//
// Message streamed back (via context.sendMessage) once the server has bound a port and is ready
// to serve. The caller reads `port` to build the restApiUrl (http://<host>:<port>).
//
export interface IAssetServerReadyMessage {
    //
    // Discriminator matched by onTaskMessage("asset-server-ready").
    //
    type: "asset-server-ready";

    //
    // The actual bound port (resolved even when port 0 was requested).
    //
    port: number;

    //
    // The host the server is bound to.
    //
    host: string;
}

//
// Result returned when the asset-server task ends (after it is cancelled).
//
export interface IAssetServerTaskResult {
    //
    // The port the server was bound to.
    //
    port: number;

    //
    // The host the server was bound to.
    //
    host: string;
}

//
// The subset of a bound server address this task reads. Declared locally so the worker does not
// import the `net` module (which is shimmed on mobile).
//
interface IBoundAddress {
    //
    // The numeric port the server bound to.
    //
    port: number;
}

//
// How often the stay-alive loop re-checks for cancellation while the server runs.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// Sleeps for the given number of milliseconds. On Node this is a real timer; in the embedded engine
// it is driven by the native pump (which fires queued timers while the task has not settled).
//
function sleep(milliseconds: number): Promise<void> {
    return new Promise<void>(resolve => {
        setTimeout(resolve, milliseconds);
    });
}

//
// Long-running asset-server task handler.
//
// It builds the transport-agnostic core, stands up an express HTTP server bound to a loopback port,
// reports the chosen port back via `asset-server-ready`, then stays alive until the task is
// cancelled, at which point it closes the server and returns. This is the same serving model used by
// the desktop asset server, run as a background task so it can also run inside the embedded mobile
// engine over the shimmed http/net layers.
//
export async function assetServerHandler(data: IAssetServerTaskData, context: ITaskContext): Promise<IAssetServerTaskResult> {
    // The asset server serves local content and must only be reachable from this machine, so it
    // always binds the loopback interface.
    const host = "127.0.0.1";
    const requestedPort = data.port ?? 0;

    const core = createAssetServerCore({
        uuidGenerator: context.uuidGenerator,
        timestampProvider: context.timestampProvider,
        sessionId: context.sessionId,
    });

    const app = express();
    attachAssetServerRoutes(app, core, true);

    const server = createServer(app);

    const boundPort = await new Promise<number>((resolve, reject) => {
        server.once("error", reject);
        server.listen(requestedPort, host, () => {
            const address = server.address() as IBoundAddress | string | null;
            if (!address || typeof address === "string") {
                reject(new Error("Asset server failed to resolve a bound port"));
                return;
            }
            resolve(address.port);
        });
    });

    log.info(`Asset server task listening on http://${host}:${boundPort}`);

    const readyMessage: IAssetServerReadyMessage = { type: "asset-server-ready", port: boundPort, host };
    context.sendMessage(readyMessage);

    // Stay alive until the task is cancelled, then shut the server down.
    while (!context.isCancelled()) {
        await sleep(CANCEL_POLL_INTERVAL_MS);
    }

    await new Promise<void>(resolve => {
        server.close(() => resolve());
    });

    log.info(`Asset server task on http://${host}:${boundPort} stopped`);

    return { port: boundPort, host };
}
