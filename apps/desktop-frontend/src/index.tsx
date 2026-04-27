import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from './app';
import '@fortawesome/fontawesome-free/css/all.css';
import './tailwind.css';
import type { IElectronAPI } from "electron-defs";

//
// Get the Electron API for forwarding errors to main process
//
const electronAPI = typeof window !== 'undefined'
    ? (window as unknown as { electronAPI: IElectronAPI }).electronAPI
    : undefined;

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
// In test mode, set up test-click and test-type IPC handlers so the test control server
// can drive UI elements by their data-id attribute.
//
if (isTestMode && electronAPI) {
    electronAPI.onMessage('test-click', (data: { dataId: string }) => {
        const element = document.querySelector(`[data-id="${data.dataId}"]`) as HTMLElement | null;
        if (element) {
            console.log(`test-click: clicking element data-id="${data.dataId}"`);
            element.click();
        }
        else {
            console.warn(`test-click: element not found data-id="${data.dataId}"`);
        }
    });
    electronAPI.onMessage('test-drop', (data: { dataId: string; paths: string[] }) => {
        const element = document.querySelector(`[data-id="${data.dataId}"]`) as HTMLElement | null;
        if (!element) {
            console.warn(`test-drop: element not found data-id="${data.dataId}"`);
            return;
        }
        console.log(`test-drop: dropping ${data.paths.length} path(s) onto data-id="${data.dataId}"`);
        const dt = new DataTransfer();
        for (const filePath of data.paths) {
            const filename = filePath.split('/').pop() || filePath;
            const file = new File([], filename);
            (file as any).__testPath = filePath;
            dt.items.add(file);
        }
        const dropEvent = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt });
        element.dispatchEvent(dropEvent);
    });
    electronAPI.onMessage('test-type', (data: { dataId: string; text: string }) => {
        const element = document.querySelector(`[data-id="${data.dataId}"] input`) as HTMLInputElement | null;
        if (element) {
            console.log(`test-type: typing into element data-id="${data.dataId}"`);
            const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
            if (nativeInputValueSetter) {
                nativeInputValueSetter.call(element, data.text);
                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
            }
        }
        else {
            console.warn(`test-type: element not found data-id="${data.dataId}"`);
        }
    });
}

const container = document.getElementById('root');
if (!container) {
    throw new Error('Root element not found');
}

const root = createRoot(container);
root.render(<App />);

