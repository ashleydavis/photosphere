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
import { useWebSocket } from "./lib/use-web-socket";
import { WebSocketQueueBackend } from "./lib/websocket-queue-backend";
import { setQueueBackend } from "task-queue";
import { PlatformProviderWeb } from "./lib/platform-provider-web";



export function App() {
    const ws = useWebSocket();    
    if (!ws) {
        // Wait for WebSocket connection before rendering
        return <div>Connecting...</div>;
    }

    // Extract theme from query parameters, default to system
    const urlParams = new URLSearchParams(window.location.search);
    // Startup theme: PHOTOSPHERE_THEME env override if set, otherwise the saved theme. See user-interface env-theme.ts.
    const savedTheme = (urlParams.get('theme') as 'light' | 'dark' | 'system') || 'system';
    const initialTheme = resolveInitialTheme(themeOverrideFromEnv(), savedTheme);
    
    const queueBackend = new WebSocketQueueBackend(ws);
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
                    <PlatformProviderWeb ws={ws}>
                        <StoriesPage />
                    </PlatformProviderWeb>
                } />
                <Route path="*" element={
                    <PlatformProviderWeb ws={ws}>
                        <ApiContextProvider value={axiosApi}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl="http://localhost:3001">
                                    <ImportContextProvider>
                                        <GalleryContextProvider>
                                            <DeleteConfirmationContextProvider>
                                                <SearchContextProvider>
                                                    <GalleryLayoutContextProvider>
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
                    </PlatformProviderWeb>
                } />
            </Routes>
        </HashRouter>
    );
}

