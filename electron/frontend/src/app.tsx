import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, GalleryContextProvider, Main, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";
import { ScanContextProvider } from "./context/scan-context";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <UploadContextProvider>
                        <ScanContextProvider>
                            <Main
                                computerPage={<ComputerPage />} 
                                />
                        </ScanContextProvider>
                    </UploadContextProvider>
                </GalleryContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
