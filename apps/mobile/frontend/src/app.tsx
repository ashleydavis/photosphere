import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AppContextProvider, AssetDatabaseProvider, GalleryContextProvider, GalleryLayoutContextProvider, IndexeddbContextProvider, Main, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ScanContextProvider } from "./context/scan-context";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <IndexeddbContextProvider>
                    <ScanContextProvider>
                        <AppContextProvider>
                            <AssetDatabaseProvider>
                                <GalleryContextProvider>
                                    <GalleryLayoutContextProvider>
                                        <UploadContextProvider>
                                            <Main
                                                computerPage={<ComputerPage />}
                                            />
                                        </UploadContextProvider>
                                    </GalleryLayoutContextProvider>
                                </GalleryContextProvider>
                            </AssetDatabaseProvider>
                        </AppContextProvider>
                    </ScanContextProvider>
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}

