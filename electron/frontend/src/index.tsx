import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import "./styles.css";
import { scanImages } from "./lib/scan";

const container = document.getElementById('app');
const root = createRoot(container!);
root.render(<App />);

scanImages()
    .then(() => console.log('Scanning complete'))
    .catch(error => console.error('Error scanning images', error));