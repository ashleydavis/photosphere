//
// Electron utility process entry point for the REST API server
// Runs the asset server in a separate process
//
import { createAssetServer } from 'rest-api';
import { RandomUuidGenerator, TimestampProvider } from 'utils';
import type { Server } from 'http';

//
// Post message function for Electron utility process
//
const parentPort = (process as any).parentPort;
if (!parentPort) {
    throw new Error('parentPort not available - this must run in an Electron utility process');
}

let server: Server | undefined = undefined;

//
// Start the asset server
//
async function startServer(port: number): Promise<void> {
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();

    const result = await createAssetServer({
        port,
        uuidGenerator,
        timestampProvider,
    });

    server = result.server;
    console.log('Asset server initialized in utility process');

    // Send ready message to main thread
    parentPort.postMessage({ type: "server-ready" });
}

//
// Stop the asset server
//
function stopServer(): void {
    if (server) {
        server.close(() => {
            console.log('Asset server stopped');
            parentPort.postMessage({ type: "server-stopped" });
        });
        server = undefined;
    }
    else {
        parentPort.postMessage({ type: "server-stopped" });
    }
}

//
// Initialize the message listener
//
parentPort.on('message', async (event: any) => {
    const message = event.data;

    if (message.type === 'start') {
        const { port } = message;
        if (!port) {
            console.error('Port is required to start the server');
            parentPort.postMessage({ type: "server-error", error: "Port is required" });
            return;
        }

        try {
            await startServer(port);
        }
        catch (error: any) {
            console.error('Failed to start asset server:', error);
            parentPort.postMessage({ 
                type: "server-error", 
                error: error.message || String(error) 
            });
        }
    }
    else if (message.type === 'stop') {
        stopServer();
    }
    else {
        console.error(`Unknown message type: ${message.type}`);
    }
});

//
// Handle uncaught errors
//
process.on('uncaughtException', (error) => {
    console.error('Uncaught exception in REST API worker:', error);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled rejection in REST API worker:', reason);
    process.exit(1);
});

//
// Handle process exit
//
process.on('exit', () => {
    if (server) {
        server.close();
    }
});

