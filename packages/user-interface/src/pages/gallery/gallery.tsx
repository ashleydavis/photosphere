import React from "react";
import { Gallery } from "../../components/gallery";
import { useDatabaseSync } from "../../context/database-sync";
import { Spinner } from "../../components/spinner";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {

    const { isInitialized } = useDatabaseSync();

    if (!isInitialized) {
        return (
            <div className="w-full h-full p-4 flex items-center justify-center">
                <Spinner show={true} />
            </div>
        );
    }

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery 
                targetRowHeight={150}
                />
        </div>
    );
}