import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";

const container = document.getElementById('app');
if (!container) {
    throw new Error('Root element not found');
}

const root = createRoot(container);
root.render(<App />);