import { useEffect, useState } from "react";
import { TaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";

//
// The source tag used for the asset-server task. Its own source (and therefore its own TaskQueue)
// keeps the long-running server logically separate so cancelling it does not affect other tasks.
//
const ASSET_SERVER_SOURCE = "asset-server";

//
// The message the asset-server task streams once it has bound a port. Declared locally so this
// package does not depend on node-api just for the message shape.
//
interface IAssetServerReadyMessage {
    //
    // Discriminator matched by onTaskMessage.
    //
    type: "asset-server-ready";

    //
    // The actual bound loopback port.
    //
    port: number;

    //
    // The host the server bound to.
    //
    host: string;
}

//
// Input data for the asset-server task. Port 0 lets the host assign a free loopback port.
//
interface IAssetServerTaskData {
    //
    // The port to bind; 0 means OS-assigned.
    //
    port: number;
}

//
// The queue running the asset-server task, created the first time the server is needed.
//
let assetServerQueue: TaskQueue | undefined = undefined;

//
// The url the asset server bound, once it has reported it.
//
let assetServerUrl: string | undefined = undefined;

//
// Everyone waiting to be told the url.
//
const urlListeners = new Set<(restApiUrl: string) => void>();

//
// Starts the asset server, once. The task is long-running and holds its task source for as long as
// it serves, so a second task under the same source would sit queued behind the first and never
// bind a port. Every caller therefore shares one server and one url: the app's gallery and the
// stories (which are mounted outside the app's provider stack) both end up here.
//
function startAssetServer(): void {
    if (assetServerQueue) {
        return;
    }

    const queue = new TaskQueue(new RandomUuidGenerator(), ASSET_SERVER_SOURCE);
    assetServerQueue = queue;

    queue.onTaskMessage<IAssetServerReadyMessage>("asset-server-ready", ({ message }) => {
        assetServerUrl = `http://localhost:${message.port}`;
        for (const listener of urlListeners) {
            listener(assetServerUrl);
        }
    });

    queue.addTask("asset-server", { port: 0 } satisfies IAssetServerTaskData);
}

//
// Starts the asset server (the first caller starts it; the rest join it) and returns the restApiUrl
// to load assets from, or undefined until the server reports the port it bound.
//
// There is no default url to fall back on: the port is assigned at runtime, so any guess points at a
// port nothing is listening on. Consumers wait for the url instead.
//
// The hook dispatches a task through whatever queue backend the host installed, so it carries no
// platform-specific code: the `asset-server` handler is registered by the mobile embedded worker and
// by node-api alike.
//
export function useAssetServer(): string | undefined {
    const [restApiUrl, setRestApiUrl] = useState<string | undefined>(assetServerUrl);

    useEffect(() => {
        //
        // Already bound: nothing to wait for.
        //
        if (assetServerUrl) {
            setRestApiUrl(assetServerUrl);
            return;
        }

        urlListeners.add(setRestApiUrl);
        startAssetServer();

        return () => {
            urlListeners.delete(setRestApiUrl);
        };
    }, []);

    return restApiUrl;
}
