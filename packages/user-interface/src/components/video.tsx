import React, { useEffect, useState } from "react";
import { log } from "utils";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";

export interface IVideoProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders an image.
//
export function Video({ asset }: IVideoProps) {

    const [objectURL, setObjectURL] = useState<string>("");

    //
    // TEMP DEBUG: tracks the <video> element's load lifecycle so we can see on screen what is
    // actually happening (mounted? src? error?). Remove once the video issue is resolved.
    //
    const [debugStatus, setDebugStatus] = useState<string>("mounted");

    const { loadAsset, unloadAsset } = useGallery();
    const { assetUrl } = useAssetDatabase();

    //
    // On the Electron desktop build the page is served from a file:// origin, where a
    // blob:file:// media URL is rejected by Chromium's media URL-safety check (the video goes
    // blank). In that case point the <video> directly at the http asset URL instead, which is the
    // same media origin that plays in the web build. On web (http origin) keep using the blob.
    //
    const useDirectUrl = window.location.protocol === "file:";

    useEffect(() => {
        if (useDirectUrl) {
            //
            // No blob is loaded for the direct-URL path, so there is nothing to load or unload.
            //
            return;
        }

        loadAsset(asset._id, "asset")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                log.exception(`Failed to load video asset: ${asset._id}`, err as Error);
            });

        return () => {
            unloadAsset(asset._id, "asset");
        };
    }, [asset]);

    //
    // The media source. On the Electron desktop (file:// origin) use the privileged psphere://
    // scheme, which the main process serves via net.fetch from the asset endpoint. This plays
    // where a blob:file:// URL is rejected. The scheme URL reuses the asset endpoint's query
    // params (id/type/db) by swapping the http origin for psphere://asset. On web use the blob.
    //
    const schemeUrl = assetUrl(asset._id, "asset").replace(/^https?:\/\/[^/]+\/asset/, "psphere://asset");
    const videoSrc = useDirectUrl
        ? `${schemeUrl}&contentType=${encodeURIComponent(asset.contentType)}`
        : objectURL;

    //
    // TEMP DEBUG: an unmissable bordered container plus an on-screen status line. This proves
    // whether the component renders, what src it uses, and what the <video> reports. Remove once
    // the video issue is resolved.
    //
    return (
        <div
            style={{
                position: "absolute",
                inset: 0,
                border: "6px solid magenta",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
            }}
            >
            <div
                style={{
                    position: "absolute",
                    top: 0,
                    left: 0,
                    right: 0,
                    zIndex: 99999,
                    background: "black",
                    color: "lime",
                    fontSize: "14px",
                    fontFamily: "monospace",
                    padding: "8px",
                    wordBreak: "break-all",
                    pointerEvents: "auto",
                }}
                >
                VIDEO DEBUG | useDirectUrl={String(useDirectUrl)} | status={debugStatus} | type={asset.contentType} | src={videoSrc || "(empty)"}
            </div>

            {videoSrc
                && <video
                    style={{ width: "100%", height: "100%", outline: "6px solid yellow" }}
                    muted={true}
                    autoPlay={true}
                    controls={true}
                    loop={true}
                    src={videoSrc}
                    onLoadStart={() => setDebugStatus("loadstart")}
                    onLoadedMetadata={loadEvent => setDebugStatus(`loadedmetadata ${loadEvent.currentTarget.videoWidth}x${loadEvent.currentTarget.videoHeight}`)}
                    onCanPlay={() => setDebugStatus("canplay")}
                    onError={errorEvent => setDebugStatus(`ERROR: ${errorEvent.currentTarget.error ? errorEvent.currentTarget.error.message : "unknown"}`)}
                    />
            }
        </div>
    );
};