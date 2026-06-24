import React from "react";
import { HashRouter, Route, Routes } from "react-router-dom";
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
    ApiContextProvider,
    axiosApi,
    StoriesPage,
} from "user-interface";
import { setQueueBackend } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { MobileQueueBackend } from "./lib/mobile-queue-backend";
import { PlatformProviderMobile } from "./lib/platform-provider-mobile";

//
// UUID generator used for task ids on mobile.
//
const uuidGenerator = new RandomUuidGenerator();

//
// The mobile queue backend is a no-op until background tasks are implemented on mobile.
//
const queueBackend = new MobileQueueBackend();
setQueueBackend(queueBackend);

//
// Root mobile app. Mounts the real Photosphere UI backed by the stubbed mobile
// platform provider. There is no WebSocket gate as on web — the UI renders immediately.
//
export function App() {
    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <Routes>
                <Route path="/stories" element={<StoriesPage />} />
                <Route path="*" element={
                    <UuidGeneratorProvider value={uuidGenerator}>
                        <PlatformProviderMobile>
                            <ApiContextProvider value={axiosApi}>
                            <AppContextProvider>
                                <ToastContextProvider>
                                    <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl="http://localhost:3001">
                                        <ImportContextProvider>
                                            <GalleryContextProvider>
                                                <DeleteConfirmationContextProvider>
                                                    <SearchContextProvider>
                                                        <GalleryLayoutContextProvider>
                                                            <Main isMobile={true} initialTheme="system" />
                                                        </GalleryLayoutContextProvider>
                                                    </SearchContextProvider>
                                                </DeleteConfirmationContextProvider>
                                            </GalleryContextProvider>
                                        </ImportContextProvider>
                                    </AssetDatabaseProvider>
                                </ToastContextProvider>
                            </AppContextProvider>
                            </ApiContextProvider>
                        </PlatformProviderMobile>
                    </UuidGeneratorProvider>
                } />
            </Routes>
        </HashRouter>
    );
}
