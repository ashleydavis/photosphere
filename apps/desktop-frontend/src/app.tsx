import React from "react";
import { HashRouter, Route, Routes } from "react-router-dom";
import {
    AppContextProvider, DeveloperContextProvider, SyncContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider,
    SearchContextProvider,
    DeleteConfirmationContextProvider,
    ImportContextProvider,
    ToastContextProvider,
    ApiContextProvider,
    axiosApi,
    StoriesPage,
    resolveInitialTheme, themeOverrideFromEnv,
} from "user-interface";
import { ElectronRendererQueueBackend } from "./lib/electron-renderer-queue-backend";
import { setQueueBackend } from "task-queue";
import { PlatformProviderElectron } from "./lib/platform-provider-electron";
import type { IElectronAPI } from "./lib/electron-ipc";
import { setLog } from "utils";
import { createRendererLog } from "./lib/renderer-log";
import { McpToolHandler } from "./lib/mcp-tool-handler";
import { PreviewBanner } from "./lib/preview-banner";


//
// Props for the App component.
//
interface IAppProps {
    // The Electron API object injected by the preload script.
    electronAPI: IElectronAPI;
}

export function App({ electronAPI }: IAppProps) {
    // Initialize renderer logging to forward logs to main process
    const rendererLog = createRendererLog(electronAPI);
    setLog(rendererLog);

    // Extract query parameters
    const urlParams = new URLSearchParams(window.location.search);
    const restApiUrl = urlParams.get('restApiUrl');
    if (!restApiUrl) {
        throw new Error('restApiUrl query parameter is required but was not provided.');
    }
    // Startup theme: PHOTOSPHERE_THEME env override if set, otherwise the saved theme. See user-interface env-theme.ts.
    const savedTheme = (urlParams.get('theme') as 'light' | 'dark' | 'system') || 'system';
    const initialTheme = resolveInitialTheme(themeOverrideFromEnv(), savedTheme);

    const queueBackend = new ElectronRendererQueueBackend(electronAPI);
    setQueueBackend(queueBackend);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <Routes>
                <Route path="/stories" element={
                    <PlatformProviderElectron electronAPI={electronAPI}>
                        <StoriesPage />
                    </PlatformProviderElectron>
                } />
                <Route path="*" element={
                    <PlatformProviderElectron electronAPI={electronAPI}>
                        <ApiContextProvider value={axiosApi}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
                                    <ImportContextProvider>
                                        <GalleryContextProvider>
                                            <DeleteConfirmationContextProvider>
                                                <SearchContextProvider>
                                                    <GalleryLayoutContextProvider>
                                                        <McpToolHandler />
                                                        <PreviewBanner />
                                                        <DeveloperContextProvider>
                                                            <SyncContextProvider>
                                                                <Main initialTheme={initialTheme} />
                                                            </SyncContextProvider>
                                                        </DeveloperContextProvider>
                                                    </GalleryLayoutContextProvider>
                                                </SearchContextProvider>
                                            </DeleteConfirmationContextProvider>
                                        </GalleryContextProvider>
                                    </ImportContextProvider>
                                </AssetDatabaseProvider>
                            </ToastContextProvider>
                        </AppContextProvider>
                        </ApiContextProvider>
                    </PlatformProviderElectron>
                } />
            </Routes>
        </HashRouter>
    );
}

