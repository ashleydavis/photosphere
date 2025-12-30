import React from "react";
import { createRoot } from 'react-dom/client';
import { App } from "./app";
import '@fortawesome/fontawesome-free/css/all.css';
import "./tailwind.css";
import { AuthContextProvider } from "user-interface";

const container = document.getElementById('app');
const root = createRoot(container!);
root.render(
    <AuthContextProvider>
        <App />
    </AuthContextProvider>
);
