import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, GalleryContextProvider, UploadContextProvider } from "user-interface";
import { Scan } from "./scan";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <UploadContextProvider>
                        <Scan />
                    </UploadContextProvider>
                </GalleryContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
