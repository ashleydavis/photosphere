import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from './app';
import '@fortawesome/fontawesome-free/css/all.css';
import './tailwind.css';
import { installTestDriver } from "user-interface";
import type { IPlatformInfo, IZiggyBridge } from "ziggy";
import { isTestMode } from "./lib/test-mode";
import { sendRendererLog } from "./lib/renderer-log";
import { createZiggyTestTransport } from "./lib/ziggy-test-transport";
import { isResizeObserverLoopReport } from "./lib/resize-observer-report";

//
// The bridge the native app injects into the page before its scripts run.
//
const ziggy: IZiggyBridge | undefined = typeof window !== 'undefined' ? window.ziggy : undefined;
if (!ziggy) {
    throw new Error('window.ziggy is not available. photosphere-frontend requires a Ziggy shell.');
}

//
// Whether the app is running in test mode (set via ?testMode=1 query param by the core).
//
const testMode = isTestMode();

//
// Handle uncaught errors in the page
//
window.onerror = (message, source, lineno, colno, error) => {
    // Late ResizeObserver notifications are not an exception (see isResizeObserverLoopReport), so they are logged as information.
    if (isResizeObserverLoopReport(message, error)) {
        console.log(`ResizeObserver delivered notifications a frame late: ${message}`);
        return true;
    }

    const errorMessage = `Uncaught error: ${message} at ${source}:${lineno}:${colno}`;
    console.error(errorMessage, error);

    sendRendererLog(ziggy, {
        level: 'exception',
        message: errorMessage,
        error: error?.stack || error?.message || String(error),
    });

    // Return false to allow the error to propagate to the console
    return false;
};

//
// Handle unhandled promise rejections in the page
//
window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    const error = reason instanceof Error ? reason : new Error(String(reason));
    const errorMessage = `Unhandled rejection: ${error.message}`;
    console.error(errorMessage, error);

    sendRendererLog(ziggy, {
        level: 'exception',
        message: errorMessage,
        error: error.stack || error.message || String(error),
    });
});

//
// In test mode, patch console to forward output to the core on the renderer-log channel
// so raw page console output appears in app.log.
//
if (testMode) {
    const originalLog = console.log.bind(console);
    const originalWarn = console.warn.bind(console);
    const originalError = console.error.bind(console);
    console.log = (...args: unknown[]) => {
        originalLog(...args);
        sendRendererLog(ziggy, { level: 'info', message: args.map(String).join(' ') });
    };
    console.warn = (...args: unknown[]) => {
        originalWarn(...args);
        sendRendererLog(ziggy, { level: 'warn', message: args.map(String).join(' ') });
    };
    console.error = (...args: unknown[]) => {
        originalError(...args);
        sendRendererLog(ziggy, { level: 'error', message: args.map(String).join(' ') });
    };
}

//
// In test mode, install the shared DOM test driver over the core's test-command events so the
// test control connection can drive UI elements by their data-id attribute. The DOM-action
// logic lives in user-interface's test-driver so it is shared with the mobile WebView. The page tells the
// core it is listening once the platform provider is mounted (see PlatformProviderZiggy), because
// some commands act through listeners the provider registers.
//
if (testMode) {
    installTestDriver(createZiggyTestTransport(ziggy));
}

//
// Asks the core what kind of device this is, then renders the app.
//
async function start(bridge: IZiggyBridge): Promise<void> {
    const platform: IPlatformInfo = await bridge.getPlatform();

    if (platform.platformKind !== "desktop" && platform.platformKind !== "mobile") {
        throw new Error(`Unknown platform kind "${String(platform.platformKind)}" from get-platform.`);
    }

    const container = document.getElementById('root');
    if (!container) {
        throw new Error('Root element not found');
    }

    const root = createRoot(container);
    root.render(<App ziggy={bridge} platform={platform} />);
}

void start(ziggy);
