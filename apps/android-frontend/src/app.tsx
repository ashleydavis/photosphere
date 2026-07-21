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
    useAssetServer,
    FullscreenSpinner,
    resolveInitialTheme, themeOverrideFromEnv,
} from "user-interface";
import { setQueueBackend } from "task-queue";
import { EmbeddedJsQueueBackend, PlatformProviderMobile } from "mobile-frontend";


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
    // as desktop. Undefined until the task reports the port it bound: there is nothing to load
    // assets from until then, so the app waits rather than building urls against a guessed port.
    const restApiUrl = useAssetServer();
    // Startup theme: PHOTOSPHERE_THEME env override if set, otherwise system. See user-interface env-theme.ts.
    const initialTheme = resolveInitialTheme(themeOverrideFromEnv(), "system");

    return (
        <HashRouter
            future={{
                v7_startTransition: true,
                v7_relativeSplatPath: true,
            }}
        >
            <Routes>
                <Route path="/stories" element={
                    <PlatformProviderMobile>
                        <StoriesPage />
                    </PlatformProviderMobile>
                } />
                <Route path="*" element={
                    !restApiUrl
                        ? <FullscreenSpinner />
                        : <PlatformProviderMobile>
                        <ApiContextProvider value={axiosApi}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
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
                    </PlatformProviderMobile>
                } />
            </Routes>
        </HashRouter>
    );
}
