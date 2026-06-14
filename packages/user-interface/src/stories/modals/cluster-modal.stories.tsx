import React from "react";
import { ClusterModal } from "../../pages/map/cluster-modal";
import { RealDatabaseProviders, StoryModalLauncher, WithRealAssets } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ClusterModal. Uses the 50-assets fixture so the clustered
// photos load real thumbnails (the modal's static gallery source delegates
// image loading to the outer real database source).
//
export const stories: IStory[] = [
    {
        id: "cluster-modal/open",
        name: "Cluster",
        category: "Modals",
        render: () => (
            <RealDatabaseProviders>
                <StoryModalLauncher label="cluster modal">
                    {(open, onClose) => open
                        ? (
                            <WithRealAssets count={5}>
                                {assets => <ClusterModal items={assets} lat={-33.8688} lng={151.2093} onClose={onClose} />}
                            </WithRealAssets>
                        )
                        : null
                    }
                </StoryModalLauncher>
            </RealDatabaseProviders>
        ),
    },
];
