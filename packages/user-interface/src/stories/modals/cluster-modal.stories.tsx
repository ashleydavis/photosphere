import React from "react";
import { ClusterModal } from "../../pages/map/cluster-modal";
import { MockProviders, mockGalleryItem, mockAssetDatabase, noOp } from "../mocks";
import type { IStory } from "../types";

//
// A fixed cluster of three assets used by the cluster-modal story.
//
const clusterItems = [
    mockGalleryItem({ _id: "cluster-1", origFileName: "harbour.jpg" }),
    mockGalleryItem({ _id: "cluster-2", origFileName: "bridge.jpg" }),
    mockGalleryItem({ _id: "cluster-3", origFileName: "skyline.jpg" }),
];

//
// Stories for the ClusterModal.
//
export const stories: IStory[] = [
    {
        id: "cluster-modal/open",
        name: "Cluster",
        category: "Modals",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(clusterItems)}>
                <ClusterModal items={clusterItems} lat={-33.8688} lng={151.2093} onClose={noOp} />
            </MockProviders>
        ),
    },
];
