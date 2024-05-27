//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";
import { Gallery, GalleryContextProvider } from "user-interface";
import path from "path";

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
            <GalleryContextProvider 
                source={scan}
                sortFn={asset => path.dirname(asset.origFileName)}
                groupFn={asset => path.dirname(asset.origFileName)}
                >
                <Gallery
                    targetRowHeight={150}
                    />
            </GalleryContextProvider>
        </div>
    );
}
