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
    const initialTheme = (urlParams.get('theme') as 'light' | 'dark' | 'system') || 'system';
    
    const queueBackend = new WebSocketQueueBackend(ws);
    setQueueBackend(queueBackend);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <PlatformProviderWeb ws={ws}>
                <ImportContextProvider>
                    <AppContextProvider>
                        <ToastContextProvider>
                            <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl="http://localhost:3001">
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
                        </ToastContextProvider>
                    </AppContextProvider>
                </ImportContextProvider>
            </PlatformProviderWeb>
        </HashRouter>
    );
}

