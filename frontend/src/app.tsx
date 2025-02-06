import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main, ApiContextProvider, UploadContextProvider,
    GalleryContextProvider,
    IndexeddbContextProvider, AssetDatabaseProvider,
    GalleryLayoutContextProvider
} from "user-interface";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <IndexeddbContextProvider>
                    <AppContextProvider>
                        <AssetDatabaseProvider>
                            <GalleryContextProvider>
                                <GalleryLayoutContextProvider>
                                    <UploadContextProvider>
                                        <Main />
                                    </UploadContextProvider>
                                </GalleryLayoutContextProvider>
                            </GalleryContextProvider>
                        </AssetDatabaseProvider>
                    </AppContextProvider>
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}

