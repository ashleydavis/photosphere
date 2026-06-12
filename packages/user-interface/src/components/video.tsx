import React from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useAssetDatabase } from "../context/asset-database-source";

export interface IVideoProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders a video.
//
export function Video({ asset }: IVideoProps) {

    const { assetUrl } = useAssetDatabase();

    return (
        <video
            muted={true}
            autoPlay={true}
            controls={true}
            loop={true}
            src={assetUrl(asset._id, "asset")}
            style={{
                padding: "2px",
                position: "absolute",
                top: "0",
                left: "0",
                right: "0",
                bottom: "0",
                width: "80%",
                height: "80%",
                margin: "auto",
                objectFit: "contain",
            }}
            />
    );
};
