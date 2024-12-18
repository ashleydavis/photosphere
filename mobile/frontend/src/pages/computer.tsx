//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";
import { Gallery, GalleryContextProvider, GalleryLayoutContextProvider } from "user-interface";
import { useComputerGallerySource } from "../context/source/computer-gallery-source-context";
import path from "path";

export function ComputerPage() {

    //
    // Reterives assets from the local computer.
    //
    const computerGallerySource = useComputerGallerySource();

    //
    // The interface for scanning local files.
    //
    const { scanImages } = useScan();

    useEffect(() => {
        scanImages();
    }, []);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <GalleryContextProvider>
                <GalleryLayoutContextProvider>
                    <Gallery />
                </GalleryLayoutContextProvider>
            </GalleryContextProvider>
        </div>
    );
}
