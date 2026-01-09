import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider
} from "user-interface";
import { TaskQueueProviderElectron } from "./lib/task-queue-provider-electron";
import type { IElectronAPI } from "electron-defs";
import { RandomUuidGenerator, TimestampProvider } from "utils";

export function App() {
    const electronAPI = typeof window !== 'undefined' ? (window as unknown as { electronAPI: IElectronAPI }).electronAPI : undefined;
    if (!electronAPI) {
        throw new Error('electronAPI not available. desktop-frontend requires Electron.');
    }

    // Extract restApiUrl from query parameters
    const urlParams = new URLSearchParams(window.location.search);
    const restApiUrl = urlParams.get('restApiUrl');
    if (!restApiUrl) {
        throw new Error('restApiUrl query parameter is required but was not provided.');
    }

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
            <AppContextProvider>
                <AssetDatabaseProvider taskQueueProvider={taskQueueProvider} restApiUrl={restApiUrl}>
                    <GalleryContextProvider>
                        <GalleryLayoutContextProvider>
                            <Main />
                        </GalleryLayoutContextProvider>
                    </GalleryContextProvider>
                </AssetDatabaseProvider>
            </AppContextProvider>
        </HashRouter>
    );
}

