import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useApp } from "../../context/app-context";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { setId: _setId, setSetId } = useApp();
    const { setId } = useParams();

    useEffect(() => {
        if (setId && setId !== _setId) {
            setSetId(setId);
        }
    }, [setId]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery 
                targetRowHeight={150}
                />
        </div>
    );
}