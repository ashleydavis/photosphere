import express, { Application } from "express";
import { findAvailablePort } from "node-utils";
import { registerTerminationCallback } from "node-utils";
import htmlTemplateStatic from "./debug-page.html" with { type: "text" };
import { readFileSync, watchFile, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// Get __dirname equivalent for ES Modules
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const htmlFilePath = join(__dirname, "debug-page.html");
const isDevelopment = existsSync(htmlFilePath);

// Use static import as primary (convert to string), override with file system in development for live reload
let htmlTemplate: string = String(htmlTemplateStatic);
let htmlTemplateLastModified = Date.now();

// Watch for file changes in development mode only
if (isDevelopment) {
    // Load from file system initially in development
    try {
        htmlTemplate = readFileSync(htmlFilePath, "utf-8");
    }
    catch (error: any) {
        // If file read fails, fall back to static import
        console.warn("Failed to read HTML file, using static import:", error.message);
    }
    
    watchFile(htmlFilePath, { interval: 500 }, (curr, prev) => {
        if (curr.mtimeMs !== prev.mtimeMs) {
            try {
                htmlTemplate = readFileSync(htmlFilePath, "utf-8");
                htmlTemplateLastModified = Date.now();
                console.log("Debug page HTML reloaded");
            }
            catch (error: any) {
                console.error("Failed to reload debug page HTML:", error.message);
            }
        }
    });
}

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

//
// State provider function type for observers
//
export type StateProvider = () => IDebugData;

//
// Registry for state providers that will be polled periodically
//
class StateProviderRegistry {
    private providers: Map<string, StateProvider> = new Map();
    private pollInterval: NodeJS.Timeout | null = null;
    private pollIntervalMs: number = 60000; // 1 minute

    /**
     * Registers a state provider that will be polled periodically.
     * @param key The key to register the provider under
     * @param provider Function that returns the current state
     */
    register(key: string, provider: StateProvider): void {
        this.providers.set(key, provider);
        
        // Trigger immediate update
        this.updateState(key, provider);
        
        // Start polling if not already started
        if (!this.pollInterval) {
            this.startPolling();
        }
    }

    /**
     * Unregisters a state provider.
     */
    unregister(key: string): void {
        this.providers.delete(key);
        
        // Stop polling if no providers left
        if (this.providers.size === 0 && this.pollInterval) {
            this.stopPolling();
        }
    }

    /**
     * Manually triggers an update for a specific provider.
     */
    updateState(key: string, provider: StateProvider): void {
        try {
            const state = provider();
            for (const [stateKey, value] of Object.entries(state)) {
                debugDataRegistry.register(`${key}.${stateKey}`, value);
            }
        }
        catch (error: any) {
            // Ignore errors from state providers
        }
    }

    /**
     * Manually triggers an update for all registered providers.
     */
    updateAll(): void {
        for (const [key, provider] of this.providers.entries()) {
            this.updateState(key, provider);
        }
    }

    private startPolling(): void {
        if (this.pollInterval) {
            return;
        }
        
        this.pollInterval = setInterval(() => {
            this.updateAll();
        }, this.pollIntervalMs);
    }

    private stopPolling(): void {
        if (this.pollInterval) {
            clearInterval(this.pollInterval);
            this.pollInterval = null;
        }
    }

    /**
     * Stops all polling and clears providers.
     */
    shutdown(): void {
        this.stopPolling();
        this.providers.clear();
    }
}

const stateProviderRegistry = new StateProviderRegistry();

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
    
    // Root endpoint - serve static HTML page
    app.get("/", (req, res) => {
        res.send(htmlTemplate);
    });
    
    // Data endpoint that returns all registered debug data
    app.get("/data", (req, res) => {
        res.json(debugDataRegistry.getAll());
    });
    
    // Live reload endpoint - returns timestamp of last HTML modification
    app.get("/reload-check", (req, res) => {
        res.json({ lastModified: htmlTemplateLastModified });
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
                stateProviderRegistry.shutdown();
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

/**
 * Registers a state provider that will be polled periodically (every minute) and on demand.
 * The provider function should return an object with keys that will be prefixed with the provided key.
 * @param key The key prefix for the state data
 * @param provider Function that returns the current state
 */
export function registerStateProvider(key: string, provider: StateProvider): void {
    stateProviderRegistry.register(key, provider);
}

/**
 * Unregisters a state provider.
 */
export function unregisterStateProvider(key: string): void {
    stateProviderRegistry.unregister(key);
}

/**
 * Manually triggers an update for a specific state provider.
 */
export function updateStateProvider(key: string): void {
    const provider = (stateProviderRegistry as any).providers.get(key);
    if (provider) {
        (stateProviderRegistry as any).updateState(key, provider);
    }
}


