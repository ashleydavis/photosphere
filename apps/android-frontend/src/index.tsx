import React from "react";
import { createRoot } from 'react-dom/client';
import { App, bootstrapMobileBackend } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";

const container = document.getElementById('app');
if (!container) {
    throw new Error('Root element not found');
}

// Initialise the native JsEngine backend (await its listener registration) before mounting
// the UI, so a listener is always registered before the first background task is dispatched.
bootstrapMobileBackend().then(() => {
    const root = createRoot(container);
    root.render(<App />);
});
