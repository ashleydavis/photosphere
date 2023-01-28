import React from "react";
import { BrowserRouter, Route, Routes, Link } from "react-router-dom";
import { GalleryPage } from "./pages/gallery";
import { UploadPage } from "./pages/upload";

export function App() {
    return (
        <BrowserRouter>
            <div className="nav">
                <div className="title">Photosphere</div>
                <Link to="/" className="link">Home</Link>
                <Link to="/upload" className="link">Upload</Link>
            </div>
            <Routes>
                <Route 
                    path="/" 
                    element={<GalleryPage />} 
                    />
                <Route 
                    path="/upload" 
                    element={<UploadPage />} 
                    />
           </Routes>
        </BrowserRouter>
    );
}