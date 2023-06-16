import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main } from "./main";
import { ApiContextProvider } from "./context/api-context";
import { GalleryContextProvider } from "./context/gallery-context";
import { UploadContextProvider } from "./context/upload-context";

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
