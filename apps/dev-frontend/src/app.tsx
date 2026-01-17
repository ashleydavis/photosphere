import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider
} from "user-interface";
import { useWebSocket } from "./lib/use-web-socket";
import { TaskQueueProviderWebSocket } from "./lib/task-queue-provider-websocket";
import { PlatformProviderWeb } from "./lib/platform-provider-web";
import { RandomUuidGenerator, TimestampProvider } from "utils";

export function App() {
    const ws = useWebSocket();    
    if (!ws) {
        // Wait for WebSocket connection before rendering
        return <div>Connecting...</div>;
    }
    
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    const taskQueueProvider = new TaskQueueProviderWebSocket(ws, uuidGenerator, timestampProvider);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <AppContextProvider>
                <PlatformProviderWeb>
                    <AssetDatabaseProvider taskQueueProvider={taskQueueProvider} restApiUrl="http://localhost:3001">
                        <GalleryContextProvider>
                            <GalleryLayoutContextProvider>
                                <Main />
                            </GalleryLayoutContextProvider>
                        </GalleryContextProvider>
                    </AssetDatabaseProvider>
                </PlatformProviderWeb>
            </AppContextProvider>
        </HashRouter>
    );
}

