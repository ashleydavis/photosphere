import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main, ApiContextProvider, GalleryContextProvider, UploadContextProvider, CloudGallerySourceContextProvider, SearchContextProvider } from "user-interface";

export function App() {
    return (
        <BrowserRouter>
            <ApiContextProvider>
                <SearchContextProvider>
                    <CloudGallerySourceContextProvider>
                        <UploadContextProvider>
                            <Main />
                        </UploadContextProvider>
                    </CloudGallerySourceContextProvider>
                </SearchContextProvider>
            </ApiContextProvider>
        </BrowserRouter>
    );
}
