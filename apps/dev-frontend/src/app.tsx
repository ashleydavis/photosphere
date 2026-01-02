import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider
} from "user-interface";
import { useWebSocket } from "./lib/use-web-socket";
import { WebSocketTaskQueueProvider } from "./lib/websocket-task-queue-provider";

export function App() {
    const ws = useWebSocket();
    
    if (!ws) {
        // Wait for WebSocket connection before rendering
        return <div>Connecting...</div>;
    }
    
    const taskQueueProvider = new WebSocketTaskQueueProvider(ws);

    return (
        <HashRouter>
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

