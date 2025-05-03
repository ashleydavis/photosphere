import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { AuthContextProvider } from "user-interface";

const container = document.getElementById('app');
const root = createRoot(container!);
root.render(
    <AuthContextProvider>
        <App />
    </AuthContextProvider>
);

//
// Register the service worker.
//
// https://css-tricks.com/add-a-service-worker-to-your-site/
//
if (navigator && navigator.serviceWorker) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('service-worker.js')
            .catch(err => {
                console.error(`Failed to register the service worker:`);
                console.error(err);
            });
    });
}