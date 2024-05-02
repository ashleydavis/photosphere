import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { GalleryContextProvider } from "../../context/gallery-context";
import { useCloudGallerySource } from "../../context/source/cloud-gallery-source-context";
import { useCloudGallerySink } from "../../context/source/cloud-gallery-sink-context";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {

    const cloudGallerySource = useCloudGallerySource();
    const cloudGallerySink = useCloudGallerySink();

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <GalleryContextProvider 
                source={cloudGallerySource}
                sink={cloudGallerySink}
                >
                <Gallery 
                    targetRowHeight={150}
                    />
            </GalleryContextProvider>
        </div>
    );
}