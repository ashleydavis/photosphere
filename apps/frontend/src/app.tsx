import React from "react";
import { HashRouter } from "react-router-dom";
import {
    AppContextProvider, Main, UploadContextProvider,
    GalleryContextProvider,
    AssetDatabaseProvider,
    GalleryLayoutContextProvider
} from "user-interface";

export function App() {
    return (
        <HashRouter>
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
        </HashRouter>
    );
}

