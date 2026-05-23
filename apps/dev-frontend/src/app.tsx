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
import { useWebSocket } from "./lib/use-web-socket";
import { WebSocketQueueBackend } from "./lib/websocket-queue-backend";
import { setQueueBackend } from "task-queue";
import { RandomUuidGenerator, TestUuidGenerator } from "utils";
import { PlatformProviderWeb } from "./lib/platform-provider-web";

//
// In test mode a deterministic TestUuidGenerator is used so smoke tests
// get reproducible task ids; otherwise the real RandomUuidGenerator is used.
//
const isTestMode = typeof window !== 'undefined'
    && new URLSearchParams(window.location.search).get('testMode') === '1';
const uuidGenerator = isTestMode ? new TestUuidGenerator() : new RandomUuidGenerator();


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
            <UuidGeneratorProvider value={uuidGenerator}>
                <PlatformProviderWeb ws={ws}>
                    <AppContextProvider>
                        <ToastContextProvider>
                            <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl="http://localhost:3001">
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
                </PlatformProviderWeb>
            </UuidGeneratorProvider>
        </HashRouter>
    );
}

