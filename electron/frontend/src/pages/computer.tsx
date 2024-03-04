//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";
import { Gallery } from "user-interface";

export function ComputerPage() {

    const { assets, scanImages } = useScan();

    useEffect(() => {
        scanImages();
    }, []);
        
    return (
        <div>
            <Gallery
                items={assets}
                onItemClick={() => {}}
                targetRowHeight={150}
                />
        </div>
    );
}