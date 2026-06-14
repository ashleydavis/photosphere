import React, { useEffect } from "react";
import { GalleryImage } from "../../components/gallery-image";
import { RealDatabaseProviders, WithRealAssets, noOp } from "../mocks";
import { useGallery } from "../../context/gallery-context";
import type { IGalleryItem } from "../../lib/gallery-item";
import type { IStory } from "../types";

//
// Props for SelectOnMount.
//
interface ISelectOnMountProps {
    //
    // The asset to mark as selected once the gallery context is ready.
    //
    item: IGalleryItem;

    //
    // Content rendered inside the selecting gallery context.
    //
    children: React.ReactNode;
}

//
// Puts the gallery into multi-select mode and selects the given item on mount,
// so the "selected" gallery-image story shows the selected (ticked) state.
//
function SelectOnMount({ item, children }: ISelectOnMountProps) {
    const { enableSelecting, addToMultipleSelection } = useGallery();
    useEffect(() => {
        enableSelecting(true);
        addToMultipleSelection(item);
    }, []);
    return <>{children}</>;
}

//
// Stories for the GalleryImage component. Uses the 50-assets fixture so a real
// thumbnail loads instead of a grey placeholder.
//
export const stories: IStory[] = [
    {
        id: "gallery-image/default",
        name: "Gallery Image (default)",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <WithRealAssets count={1}>
                    {assets => (
                        <div style={{ position: "relative", width: "200px", height: "200px" }}>
                            <GalleryImage item={assets[0]} onClick={noOp} x={0} y={0} width={200} height={200} />
                        </div>
                    )}
                </WithRealAssets>
            </RealDatabaseProviders>
        ),
    },
    {
        id: "gallery-image/selected",
        name: "Gallery Image (selected)",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <WithRealAssets count={1}>
                    {assets => (
                        <SelectOnMount item={assets[0]}>
                            <div style={{ position: "relative", width: "200px", height: "200px" }}>
                                <GalleryImage item={assets[0]} onClick={noOp} x={0} y={0} width={200} height={200} />
                            </div>
                        </SelectOnMount>
                    )}
                </WithRealAssets>
            </RealDatabaseProviders>
        ),
    },
];
