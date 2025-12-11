import express, { Application } from "express";
import { findAvailablePort } from "node-utils";
import { registerTerminationCallback } from "node-utils";

export interface IDebugData {
    [key: string]: any;
}

class DebugDataRegistry {
    private data: IDebugData = {};

    /**
     * Registers or updates debug data.
     * @param key The key to register the data under
     * @param value The JSON-serializable data to register
     */
    register(key: string, value: any): void {
        this.data[key] = value;
    }

    /**
     * Gets all registered debug data.
     */
    getAll(): IDebugData {
        return { ...this.data };
    }

    /**
     * Clears all registered debug data.
     */
    clear(): void {
        this.data = {};
    }
}

const debugDataRegistry = new DebugDataRegistry();

export interface IDebugServerOptions {
    /**
     * The port to run the debug server on.
     * Defaults to 0 (random available port).
     */
    port?: number;
    
    /**
     * Initial data to register when starting the server.
     */
    initialData?: IDebugData;
    
    /**
     * Whether to automatically open the browser.
     * Defaults to false.
     */
    openBrowser?: boolean;
    
    /**
     * Callback to open the browser. If not provided, uses the 'open' package.
     */
    openBrowserFn?: (url: string) => Promise<void>;
    
    /**
     * Whether to register a termination callback to close the server on exit.
     * Defaults to true.
     */
    registerTerminationHandler?: boolean;
}

export interface IDebugServer {
    /**
     * The port the server is listening on.
     */
    port: number;

    /**
     * Stops the debug server.
     */
    stop(): Promise<void>;
}

/**
 * Starts the debug REST API server.
 * @param options Server configuration options
 * @returns Promise resolving to the server instance and URL
 */
export async function startDebugServer(options: IDebugServerOptions = {}): Promise<{ server: IDebugServer; url: string }> {
    // Find available port if not specified
    const port = options.port ?? await findAvailablePort();
    
    const app: Application = express();
    
    // Root endpoint that returns all registered debug data
    app.get("/", (req, res) => {
        res.json(debugDataRegistry.getAll());
    });

    const server = await new Promise<IDebugServer>((resolve, reject) => {
        const httpServer = app.listen(port, () => {
            const address = httpServer.address();
            const actualPort = typeof address === 'object' && address !== null ? address.port : port;
            
            resolve({
                port: actualPort,
                stop: async () => {
                    return new Promise<void>((resolveStop, rejectStop) => {
                        httpServer.close((err) => {
                            if (err) {
                                rejectStop(err);
                            }
                            else {
                                resolveStop();
                            }
                        });
                    });
                }
            });
        });

        httpServer.on('error', reject);
    });
    
    const url = `http://localhost:${server.port}`;
    
    // Register initial data if provided
    if (options.initialData) {
        for (const [key, value] of Object.entries(options.initialData)) {
            registerDebugData(key, value);
        }
    }
    
    // Register termination callback if requested (defaults to true)
    if (options.registerTerminationHandler !== false) {
        registerTerminationCallback(async () => {
            try {
                await server.stop();
            }
            catch (error: any) {
                // Ignore cleanup errors
            }
        });
    }
    
    // Open browser if requested
    if (options.openBrowser) {
        const openFn = options.openBrowserFn || (async (url: string) => {
            // Dynamic import to avoid requiring 'open' as a dependency
            const open = await import("open");
            await open.default(url);
        });
        
        openFn(url).catch((err) => {
            console.error("Failed to open browser:", err);
        });
    }
    
    return { server, url };
}

/**
 * Registers debug data that will be exposed via the REST API.
 * @param key The key to register the data under
 * @param value The JSON-serializable data to register
 */
export function registerDebugData(key: string, value: any): void {
    debugDataRegistry.register(key, value);
}

/**
 * Gets all currently registered debug data.
 */
export function getDebugData(): IDebugData {
    return debugDataRegistry.getAll();
}


