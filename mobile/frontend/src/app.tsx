import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, CloudGallerySourceContextProvider, GalleryContextProvider, Main, SearchContextProvider, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ComputerGallerySourceContextProvider } from "./context/source/computer-gallery-source-context";
import { ScanContextProvider } from "./context/scan-context";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <SearchContextProvider>
                    <CloudGallerySourceContextProvider>
                        <ScanContextProvider>
                            <ComputerGallerySourceContextProvider>
                                <UploadContextProvider>
                                        <Main
                                            computerPage={<ComputerPage />} 
                                            />
                                </UploadContextProvider>
                            </ComputerGallerySourceContextProvider>
                        </ScanContextProvider>
                    </CloudGallerySourceContextProvider>
                </SearchContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
