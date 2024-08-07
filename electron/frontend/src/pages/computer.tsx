//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";
import { Gallery, GalleryContextProvider } from "user-interface";

export function ComputerPage() {

    //
    // The interface for scanning local files.
    //
    const scan = useScan();

    useEffect(() => {
        scan.scanImages();
    }, []);
        
    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <GalleryContextProvider>
                <Gallery
                    targetRowHeight={150}
                    getHeadings={undefined}
                    />
            </GalleryContextProvider>
        </div>
    );
}
