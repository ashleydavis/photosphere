import React from "react";
import { Gallery } from "../../components/gallery";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery 
                targetRowHeight={150}
                />
        </div>
    );
}