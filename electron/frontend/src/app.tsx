import React from "react";
import { HashRouter } from "react-router-dom";
import { Main, ApiContextProvider, GalleryContextProvider, UploadContextProvider } from "user-interface";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <UploadContextProvider>
                        <Main />
                    </UploadContextProvider>
                </GalleryContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
