import React from "react";
import { HashRouter } from "react-router-dom";
import { ApiContextProvider, GalleryContextProvider, Main, UploadContextProvider } from "user-interface";
import { ComputerPage } from "./pages/computer";

export function App() {
    return (
        <HashRouter>
            <ApiContextProvider>
                <GalleryContextProvider>
                    <UploadContextProvider>
                        <Main
                            computerPage={<ComputerPage />} 
                            />
                    </UploadContextProvider>
                </GalleryContextProvider>
            </ApiContextProvider>
        </HashRouter>
    );
}
