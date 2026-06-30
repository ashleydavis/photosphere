import { useEffect, useRef, useState } from "react";
import { TaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";

//
// The source tag used for the asset-server task. Its own source (and therefore its own TaskQueue)
// keeps the long-running server logically separate so cancelling it does not affect other tasks.
//
const ASSET_SERVER_SOURCE = "asset-server";

//
// The restApiUrl used before the asset-server task reports its bound port. Matches the historical
// mobile default so behaviour is unchanged until the real port is known (and in browser previews
// without the native engine, where the task never reports ready).
//
const DEFAULT_REST_API_URL = "http://localhost:3001";

//
// The message the asset-server task streams once it has bound a port. Declared locally so this
// frontend package does not depend on node-api just for the message shape.
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
// Input data for the asset-server task. Port 0 lets the native side assign a free loopback port.
//
interface IAssetServerTaskData {
    //
    // The port to bind; 0 means OS-assigned.
    //
    port: number;
}

//
// Starts the long-running asset-server background task (in the embedded engine on device) and
// returns the restApiUrl the WebView should use to load assets. Until the task reports its bound
// port via the `asset-server-ready` message, the historical default URL is returned, so the gallery
// builds the same `http://localhost:<port>/asset?...` URLs as desktop once the server is up.
//
export function useMobileAssetServer(): string {
    const [restApiUrl, setRestApiUrl] = useState<string>(DEFAULT_REST_API_URL);
    const queueRef = useRef<TaskQueue | undefined>(undefined);

    useEffect(() => {
        const queue = new TaskQueue(new RandomUuidGenerator(), ASSET_SERVER_SOURCE);
        queueRef.current = queue;

        const unsubscribe = queue.onTaskMessage<IAssetServerReadyMessage>("asset-server-ready", ({ message }) => {
            setRestApiUrl(`http://localhost:${message.port}`);
        });

        queue.addTask("asset-server", { port: 0 } satisfies IAssetServerTaskData);

        return () => {
            unsubscribe();
            queue.shutdown();
            queueRef.current = undefined;
        };
    }, []);

    return restApiUrl;
}
