import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider,
    SearchContextProvider,
    DeleteConfirmationContextProvider
} from "user-interface";
import { TaskQueueProviderElectron } from "./lib/task-queue-provider-electron";
import { PlatformProviderElectron } from "./lib/platform-provider-electron";
import type { IElectronAPI } from "electron-defs";
import { RandomUuidGenerator, TimestampProvider, setLog } from "utils";
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

    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    const taskQueueProvider = new TaskQueueProviderElectron(electronAPI, uuidGenerator, timestampProvider);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <PlatformProviderElectron electronAPI={electronAPI}>
                <AppContextProvider>
                    <AssetDatabaseProvider taskQueueProvider={taskQueueProvider} restApiUrl={restApiUrl}>
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
            </PlatformProviderElectron>
        </HashRouter>
    );
}

