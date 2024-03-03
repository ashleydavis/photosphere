//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect } from "react";
import { useScan } from "../context/scan-context";

export function ComputerPage() {

    const { scanImages } = useScan();

    useEffect(() => {
        scanImages();
    }, []);
        
    return (
        <div>
            Placeholder
        </div>
    );
}