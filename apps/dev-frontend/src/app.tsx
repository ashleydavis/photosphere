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

export function App() {
    const ws = useWebSocket();    
    if (!ws) {
        // Wait for WebSocket connection before rendering
        return <div>Connecting...</div>;
    }
    
    const taskQueueProvider = new TaskQueueProviderWebSocket(ws);

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <AppContextProvider>
                <AssetDatabaseProvider taskQueueProvider={taskQueueProvider}>
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

