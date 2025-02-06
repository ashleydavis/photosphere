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
                    <AssetDatabaseProvider>
                        <GalleryContextProvider>
                            <GalleryLayoutContextProvider>
                                <UploadContextProvider>
                                    <ScanContextProvider>
                                        <Main
                                            computerPage={<ComputerPage />}
                                        />
                                    </ScanContextProvider>
                                </UploadContextProvider>
                            </GalleryLayoutContextProvider>
                        </GalleryContextProvider>
                    </AssetDatabaseProvider>
                </IndexeddbContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
