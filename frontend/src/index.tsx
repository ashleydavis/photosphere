import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import { ApiContextProvider } from "./context/api-context";
import { GalleryContextProvider } from "./context/gallery-context";

const container = document.getElementById('app');
const root = createRoot(container!);
root.render(
    <ApiContextProvider>
        <GalleryContextProvider>
            <App />
        </GalleryContextProvider>
    </ApiContextProvider>
);