import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from './app';
import '@fortawesome/fontawesome-free/css/all.css';
import './tailwind.css';
import type { IElectronAPI, LogLevel } from "./lib/electron-ipc";
import { installTestDriver, getValue } from "user-interface";
import type { ITestTransport, ITestCommandPayload } from "user-interface";

declare global {
    interface Window {
        // The shared test driver's element-value reader, installed in test mode only. The main
        // process's test control server calls it through executeJavaScript to serve /get-value,
        // because the read has to happen in the renderer where the DOM is.
        __photosphereGetValue?: (dataId: string) => string;
    }
}

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
// In test mode, patch console to forward output to main process via electronAPI.log
// so raw renderer console output appears in app.log.
//
if (isTestMode && electronAPI) {
    const originalLog = console.log.bind(console);
    const originalWarn = console.warn.bind(console);
    const originalError = console.error.bind(console);
    console.log = (...args: unknown[]) => {
        originalLog(...args);
        electronAPI.log({ level: 'info', message: args.map(String).join(' ') });
    };
    console.warn = (...args: unknown[]) => {
        originalWarn(...args);
        electronAPI.log({ level: 'warn', message: args.map(String).join(' ') });
    };
    console.error = (...args: unknown[]) => {
        originalError(...args);
        electronAPI.log({ level: 'error', message: args.map(String).join(' ') });
    };
}

//
// In test mode, install the shared DOM test driver over an Electron-IPC transport so the
// test control server can drive UI elements by their data-id attribute. The DOM-action
// logic lives in user-interface's test-driver so it is shared with the mobile WebView.
//
if (isTestMode && electronAPI) {
    const transport: ITestTransport = {
        onCommand(handler: (command: string, payload: ITestCommandPayload) => Promise<string | undefined>): void {
            electronAPI.onMessage('test-click', (data: ITestCommandPayload) => { void handler('click', data); });
            electronAPI.onMessage('test-long-press-click', (data: ITestCommandPayload) => { void handler('long-press-click', data); });
            electronAPI.onMessage('test-long-press', (data: ITestCommandPayload) => { void handler('long-press', data); });
            electronAPI.onMessage('test-type', (data: ITestCommandPayload) => { void handler('type', data); });
            electronAPI.onMessage('test-drop', (data: ITestCommandPayload) => { void handler('drop', data); });
        },
        sendLog(level: string, message: string): void {
            electronAPI.log({ level: level as LogLevel, message });
        },
    };
    installTestDriver(transport);

    // The driver's value reader has no command of its own on this transport: the test control server
    // reads values straight out of the renderer with executeJavaScript, so it needs the function
    // published where that can reach it.
    window.__photosphereGetValue = getValue;
}

const container = document.getElementById('root');
if (!container) {
    throw new Error('Root element not found');
}

const root = createRoot(container);
root.render(<App electronAPI={electronAPI} />);

