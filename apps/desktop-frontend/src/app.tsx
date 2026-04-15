import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider,
    SearchContextProvider,
    DeleteConfirmationContextProvider,
    ImportContextProvider
} from "user-interface";
import { ElectronRendererQueueBackend } from "./lib/electron-renderer-queue-backend";
import { setQueueBackend } from "task-queue";
import { PlatformProviderElectron } from "./lib/platform-provider-electron";
import type { IElectronAPI } from "electron-defs";
import { setLog } from "utils";
import { createRendererLog } from "./lib/renderer-log";

export function App() {
    const electronAPI = typeof window !== 'undefined' ? (window as unknown as { electronAPI: IElectronAPI }).electronAPI : undefined;
    if (!electronAPI) {
        throw new Error('electronAPI not available. desktop-frontend requires Electron.');
    }

    // Initialize renderer logging to forward logs to main process
    const rendererLog = createRendererLog(electronAPI);
    setLog(rendererLog);

    // Extract query parameters
    const urlParams = new URLSearchParams(window.location.search);
    const restApiUrl = urlParams.get('restApiUrl');
    if (!restApiUrl) {
        throw new Error('restApiUrl query parameter is required but was not provided.');
    }
    const initialTheme = (urlParams.get('theme') as 'light' | 'dark' | 'system') || 'system';

    const queueBackend = new ElectronRendererQueueBackend(electronAPI);
    setQueueBackend(queueBackend);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <PlatformProviderElectron electronAPI={electronAPI}>
                <ImportContextProvider>
                <AppContextProvider>
                    <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
                        <GalleryContextProvider>
                            <DeleteConfirmationContextProvider>
                                <SearchContextProvider>
                                    <GalleryLayoutContextProvider>
                                        <Main isMobile={false} initialTheme={initialTheme} />
                                    </GalleryLayoutContextProvider>
                                </SearchContextProvider>
                            </DeleteConfirmationContextProvider>
                        </GalleryContextProvider>
                    </AssetDatabaseProvider>
                </AppContextProvider>
                </ImportContextProvider>
            </PlatformProviderElectron>
        </HashRouter>
    );
}

