import React from "react";
import { BrowserRouter } from "react-router-dom";
import { Main } from "./main";
import { ApiContextProvider } from "./context/api-context";
import { GalleryContextProvider } from "./context/gallery-context";

export function App() {
    return (
        <BrowserRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <Main />
                </GalleryContextProvider>
            </ApiContextProvider>
        </BrowserRouter>
    );
}
