import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, AssetDatabaseProvider, GalleryContextProvider, GalleryLayoutContextProvider, IndexeddbContextProvider, Main, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ScanContextProvider } from "./context/scan-context";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <IndexeddbContextProvider>
                    <ScanContextProvider>
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
                    </ScanContextProvider>
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}

