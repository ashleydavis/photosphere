import express from "express";
import type { Application } from "express";
import { createServer, type Server } from "http";
import { createAssetServerCore, attachAssetServerRoutes } from "node-api";
import { type IUuidGenerator, type ITimestampProvider, log } from "utils";

//
// Options for creating the asset server.
//
export interface IAssetServerOptions {
    //
    // Port to listen on (required if app is not provided).
    //
    port?: number;

    //
    // Existing Express app to attach routes to (optional).
    // If provided, routes will be attached to this app instead of creating a new one.
    //
    app?: Application;

    //
    // UUID generator to use.
    //
    uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider to use.
    //
    timestampProvider: ITimestampProvider;

    //
    // Write-lock owner for apply-database-ops (see acquireWriteLock).
    //
    sessionId: string;

}

//
// Result from creating the asset server.
//
export interface IAssetServerResult {
    //
    // The Express application.
    //
    app: Application;

    //
    // The HTTP server (only if a new server was created).
    //
    server?: Server;
}

//
// Creates and starts an asset server.
//
export async function createAssetServer(options: IAssetServerOptions): Promise<IAssetServerResult> {
    const { port, app: existingApp, uuidGenerator, timestampProvider, sessionId } = options;

    // Build the transport-agnostic core that owns the storage cache and serve/write/apply logic.
    const core = createAssetServerCore({ uuidGenerator, timestampProvider, sessionId });

    // Use existing app or create new one. CORS is only added when this server owns the app.
    const app = existingApp || express();
    attachAssetServerRoutes(app, core, !existingApp);

    // If we have an existing app, don't create a new server
    if (existingApp) {
        return {
            app,
        };
    }

    // Create HTTP server from Express app
    if (!port) {
        throw new Error("Port is required when creating a new server");
    }

    const server = createServer(app);

    // Start server
    await new Promise<void>((resolve) => {
        server.listen(port, "127.0.0.1", () => {
            log.info(`Asset server running on http://localhost:${port}`);
            resolve();
        });
    });

    return {
        app,
        server,
    };
}
