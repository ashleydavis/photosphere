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
import { EmbeddedJsQueueBackend, PlatformProviderMobile, useMobileAssetServer } from "mobile-frontend";

//
// UUID generator used for task ids on mobile.
//
const uuidGenerator = new RandomUuidGenerator();

//
// The mobile queue backend dispatches background tasks into the native embedded JS engine
// via the JsEngine Capacitor plugin.
//
const queueBackend = new EmbeddedJsQueueBackend();

//
// Registers the native JsEngine event listeners, then installs the backend as the process
// queue backend. Called from index.tsx before the app renders so a listener is always
// registered before the first task can be dispatched. A failed init (for example running in
// a browser preview without the native plugin) is logged but does not block the UI.
//
export async function bootstrapMobileBackend(): Promise<void> {
    try {
        await queueBackend.init();
    }
    catch (error) {
        console.error("Failed to initialise the mobile JsEngine backend:", error);
    }
    setQueueBackend(queueBackend);
}

//
// Root mobile app. Mounts the real Photosphere UI backed by the stubbed mobile
// platform provider. There is no WebSocket gate as on web — the UI renders immediately.
//
export function App() {
    // Start the asset-server background task (in the embedded engine) and use its bound localhost
    // port as the restApiUrl, so the gallery loads thumbnails/images/video over the same URL model
    // as desktop. Falls back to the default URL until the task reports its port.
    const restApiUrl = useMobileAssetServer();

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
                                    <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
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
