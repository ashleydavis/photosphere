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
            data-id="asset-video"
            muted={true}
            autoPlay={true}
            controls={true}
            loop={true}
            src={assetUrl(asset._id, "asset")}
            style={{
                position: "absolute",
                top: "0",
                left: "0",
                right: "0",
                bottom: "0",
                width: "100%",
                height: "100%",
                margin: "auto",
                objectFit: "contain",
                pointerEvents: "auto",
            }}
            />
    );
};
