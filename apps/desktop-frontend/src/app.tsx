import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider,
    SearchContextProvider,
    DeleteConfirmationContextProvider,
    ImportContextProvider,
    ToastContextProvider,
    UuidGeneratorProvider,
} from "user-interface";
import { ElectronRendererQueueBackend } from "./lib/electron-renderer-queue-backend";
import { setQueueBackend } from "task-queue";
import { PlatformProviderElectron } from "./lib/platform-provider-electron";
import type { IElectronAPI } from "./lib/electron-ipc";
import { setLog, RandomUuidGenerator, TestUuidGenerator } from "utils";
import { createRendererLog } from "./lib/renderer-log";

//
// In test mode a deterministic TestUuidGenerator is used so smoke tests
// get reproducible task ids; otherwise the real RandomUuidGenerator is used.
//
const isTestMode = typeof window !== 'undefined'
    && new URLSearchParams(window.location.search).get('testMode') === '1';
const uuidGenerator = isTestMode ? new TestUuidGenerator() : new RandomUuidGenerator();

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
            <UuidGeneratorProvider value={uuidGenerator}>
                <PlatformProviderElectron electronAPI={electronAPI}>
                    <AppContextProvider>
                        <ToastContextProvider>
                            <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
                                <ImportContextProvider>
                                    <GalleryContextProvider>
                                        <DeleteConfirmationContextProvider>
                                            <SearchContextProvider>
                                                <GalleryLayoutContextProvider>
                                                    <Main isMobile={false} initialTheme={initialTheme} />
                                                </GalleryLayoutContextProvider>
                                            </SearchContextProvider>
                                        </DeleteConfirmationContextProvider>
                                    </GalleryContextProvider>
                                </ImportContextProvider>
                            </AssetDatabaseProvider>
                        </ToastContextProvider>
                    </AppContextProvider>
                </PlatformProviderElectron>
            </UuidGeneratorProvider>
        </HashRouter>
    );
}

