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

export function App() {
    const electronAPI = typeof window !== 'undefined' ? (window as unknown as { electronAPI: IElectronAPI }).electronAPI : undefined;
    if (!electronAPI) {
        throw new Error('electronAPI not available. desktop-frontend requires Electron.');
    }

    const taskQueueProvider = new TaskQueueProviderElectron(electronAPI);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <AppContextProvider>
                <AssetDatabaseProvider taskQueueProvider={taskQueueProvider} restApiUrl="http://localhost:3001">
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

