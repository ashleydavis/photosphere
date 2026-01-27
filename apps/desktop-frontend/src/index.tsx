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

const container = document.getElementById('root');
if (!container) {
    throw new Error('Root element not found');
}

const root = createRoot(container);
root.render(<App />);

