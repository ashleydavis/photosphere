//
// Electron utility process entry point for the REST API server
// Runs the asset server in a separate process
//
import { createAssetServer } from 'rest-api';
import { RandomUuidGenerator, TimestampProvider, setLog, log } from 'utils';
import type { Server } from 'http';
import { createWorkerLog } from './lib/worker-log-electron';

//
// REST API worker message types
//
export interface IRestApiWorkerStartMessage {
    type: "start";
    port: number;
}

export interface IRestApiWorkerStopMessage {
    type: "stop";
}

export type IRestApiWorkerMessage = IRestApiWorkerStartMessage | IRestApiWorkerStopMessage;

export interface IRestApiWorkerServerReadyMessage {
    type: "server-ready";
}

export interface IRestApiWorkerServerStoppedMessage {
    type: "server-stopped";
}

export interface IRestApiWorkerServerErrorMessage {
    type: "server-error";
    error: string;
}

export type IRestApiWorkerResponseMessage = IRestApiWorkerServerReadyMessage | IRestApiWorkerServerStoppedMessage | IRestApiWorkerServerErrorMessage;

//
// Post message function for Electron utility process
//
const parentPort = (process as any).parentPort;
if (!parentPort) {
    throw new Error('parentPort not available - this must run in an Electron utility process');
}

// Initialize logging to send messages to main process
setLog(createWorkerLog(false, false));

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
    log.info('Asset server initialized in utility process');

    // Send ready message to main thread
    const readyMessage: IRestApiWorkerServerReadyMessage = { type: "server-ready" };
    parentPort.postMessage(readyMessage);
}

//
// Stop the asset server
//
function stopServer(): void {
    if (server) {
        server.close(() => {
            log.info('Asset server stopped');
            const stoppedMessage: IRestApiWorkerServerStoppedMessage = { type: "server-stopped" };
            parentPort.postMessage(stoppedMessage);
        });
        server = undefined;
    }
    else {
        const stoppedMessage: IRestApiWorkerServerStoppedMessage = { type: "server-stopped" };
        parentPort.postMessage(stoppedMessage);
    }
}

//
// Initialize the message listener
//
parentPort.on('message', async (event: { data: IRestApiWorkerMessage }) => {
    const message: IRestApiWorkerMessage = event.data;

    if (message.type === 'start') {
        const port = message.port;
        if (!port) {
            log.error('Port is required to start the server');
            const errorMessage: IRestApiWorkerServerErrorMessage = { type: "server-error", error: "Port is required" };
            parentPort.postMessage(errorMessage);
            return;
        }

        try {
            await startServer(port);
        }
        catch (error: any) {
            log.exception('Failed to start asset server', error);
            const errorMessage: IRestApiWorkerServerErrorMessage = { 
                type: "server-error", 
                error: error.message || String(error) 
            };
            parentPort.postMessage(errorMessage);
        }
    }
    else if (message.type === 'stop') {
        stopServer();
    }
});

//
// Handle uncaught errors
//
process.on('uncaughtException', (error) => {
    log.exception('Uncaught exception in REST API worker', error);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    const error = reason instanceof Error ? reason : new Error(String(reason));
    log.exception('Unhandled rejection in REST API worker', error);
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

