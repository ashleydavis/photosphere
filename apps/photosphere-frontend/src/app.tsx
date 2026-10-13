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
    JobsContextProvider,
    ToastContextProvider,
    ApiContextProvider,
    axiosApi,
    StoriesPage,
    resolveInitialTheme, themeOverrideFromEnv,
} from "user-interface";
import { ZiggyQueueBackend } from "./lib/ziggy-queue-backend";
import { setQueueBackend } from "task-queue";
import { PlatformProviderZiggy, type IPlatformInfo } from "./lib/platform-provider-ziggy";
import type { IZiggyBridge } from "ziggy-ui";
import { setLog } from "utils";
import { createRendererLog } from "./lib/renderer-log";
import { isTestMode } from "./lib/test-mode";
import { McpToolHandler } from "./lib/mcp-tool-handler";
import { PreviewBanner } from "./lib/preview-banner";


//
// Props for the App component.
//
interface IAppProps {
    // The bridge the shell injects into the page.
    ziggy: IZiggyBridge;

    // What the core reported about the device the app runs on.
    platform: IPlatformInfo;
}

export function App({ ziggy, platform }: IAppProps) {
    // Initialize renderer logging to forward logs to the core
    const rendererLog = createRendererLog(ziggy, isTestMode());
    setLog(rendererLog);

    // Extract query parameters
    const urlParams = new URLSearchParams(window.location.search);
    const restApiUrl = urlParams.get('restApiUrl');
    if (!restApiUrl) {
        throw new Error('restApiUrl query parameter is required but was not provided.');
    }
    // Startup theme: PHOTOSPHERE_THEME env override if set, otherwise the saved theme. See user-interface env-theme.ts.
    const savedTheme = (urlParams.get('theme') as 'light' | 'dark' | 'system') || 'system';
    const initialTheme = resolveInitialTheme(themeOverrideFromEnv(), savedTheme);

    const queueBackend = new ZiggyQueueBackend(ziggy);
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
                    <PlatformProviderZiggy ziggy={ziggy} platform={platform}>
                        <StoriesPage />
                    </PlatformProviderZiggy>
                } />
                <Route path="*" element={
                    <PlatformProviderZiggy ziggy={ziggy} platform={platform}>
                        <ApiContextProvider value={axiosApi}>
                        <AppContextProvider>
                            <ToastContextProvider>
                                <JobsContextProvider>
                                <AssetDatabaseProvider queueBackend={queueBackend} restApiUrl={restApiUrl}>
                                    <ImportContextProvider>
                                        <GalleryContextProvider>
                                            <DeleteConfirmationContextProvider>
                                                <SearchContextProvider>
                                                    <GalleryLayoutContextProvider>
                                                        {platform.platformKind === "desktop" && <McpToolHandler ziggy={ziggy} />}
                                                        {platform.platformKind === "desktop" && <PreviewBanner />}
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
                                </JobsContextProvider>
                            </ToastContextProvider>
                        </AppContextProvider>
                        </ApiContextProvider>
                    </PlatformProviderZiggy>
                } />
            </Routes>
        </HashRouter>
    );
}
