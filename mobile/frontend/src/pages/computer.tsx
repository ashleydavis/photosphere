//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";
import { Gallery, GalleryContextProvider } from "user-interface";
import { useComputerGallerySource } from "../context/source/computer-gallery-source-context";

export function ComputerPage() {

    //
    // Reterives assets from the local computer.
    //
    const computerGallerySource = useComputerGallerySource();

    //
    // The interface for scanning local files.
    //
    const { assets, scanImages } = useScan();

    useEffect(() => {
        scanImages();
    }, []);
        
    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <GalleryContextProvider 
                source={computerGallerySource}
                >
                <Gallery
                    items={assets}
                    targetRowHeight={150}
                    />
            </GalleryContextProvider>
        </div>
    );
}
