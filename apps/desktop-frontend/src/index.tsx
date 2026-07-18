import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from './app';
import '@fortawesome/fontawesome-free/css/all.css';
import './tailwind.css';
import type { IElectronAPI } from "./lib/electron-ipc";
import { connectTestDriverWebSocket } from "user-interface";


//
// Get the Electron API for forwarding errors to main process
//
const electronAPI = typeof window !== 'undefined'
    ? (window as unknown as { electronAPI: IElectronAPI }).electronAPI
    : undefined;
if (!electronAPI) {
    throw new Error('electronAPI not available. desktop-frontend requires Electron.');
}

//
// Whether the app is running in test mode (set via ?testMode=1 query param by main process).
//
const isTestMode = typeof window !== 'undefined'
    && new URLSearchParams(window.location.search).get('testMode') === '1';

//
// Host control bridge port (set via ?testBridgePort= by main process from PHOTOSPHERE_TEST_PORT).
//
const testBridgePort = typeof window !== 'undefined'
    ? new URLSearchParams(window.location.search).get('testBridgePort')
    : null;

//
// Handle uncaught errors in the renderer process
//
window.onerror = (message, source, lineno, colno, error) => {
    const errorMessage = `Uncaught error: ${message} at ${source}:${lineno}:${colno}`;
    console.error(errorMessage, error);
    
    if (electronAPI) {
        electronAPI.log({
            level: 'exception',
            message: errorMessage,
            error: error?.stack || error?.message || String(error),
        });
    }
    
    // Return false to allow the error to propagate to the console
    return false;
};

//
// Handle unhandled promise rejections in the renderer process
//
window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    const error = reason instanceof Error ? reason : new Error(String(reason));
    const errorMessage = `Unhandled rejection: ${error.message}`;
    console.error(errorMessage, error);
    
    if (electronAPI) {
        electronAPI.log({
            level: 'exception',
            message: errorMessage,
            error: error.stack || error.message || String(error),
        });
    }
});

//
// In test mode, connect the shared DOM test driver to the host control bridge over WebSocket.
// Console forwarding is handled by the WS client's patchConsole. Screenshot/quit stay in the
// Electron main process and are reached via platformHandlers → IPC.
//
if (isTestMode && electronAPI && testBridgePort) {
    connectTestDriverWebSocket(`ws://localhost:${testBridgePort}`, {
        screenshot: async () => {
            return await electronAPI.capturePage();
        },
        quit: async () => {
            electronAPI.quit();
            return undefined;
        },
    });
}

const container = document.getElementById('root');
if (!container) {
    throw new Error('Root element not found');
}

const root = createRoot(container);
root.render(<App electronAPI={electronAPI} />);
