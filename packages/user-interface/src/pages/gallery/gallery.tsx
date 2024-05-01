import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { GalleryContextProvider } from "../../context/gallery-context";
import { useCloudGallerySource } from "../../context/source/cloud-gallery-source-context";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {

    //
    // Retreives assets from the cloud.
    //
    const cloudGallerySource = useCloudGallerySource();

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <GalleryContextProvider 
                source={cloudGallerySource}
                sink={cloudGallerySource}
                >
                <Gallery 
                    targetRowHeight={150}
                    />
            </GalleryContextProvider>
        </div>
    );
}