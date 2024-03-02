import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, GalleryContextProvider, UploadContextProvider } from "user-interface";

export function App() {
    return (
        <BrowserRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <UploadContextProvider>
                        <Main />
                    </UploadContextProvider>
                </GalleryContextProvider>
            </ApiContextProvider>
        </BrowserRouter>
    );
}
