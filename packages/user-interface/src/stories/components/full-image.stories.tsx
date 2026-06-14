import React from "react";
import { FullImage } from "../../components/full-image";
import { RealDatabaseProviders, WithRealAssets } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the FullImage component. Uses the 50-assets fixture so a real
// photo loads. FullImage positions its image absolutely, so it is hosted in a
// sized, relatively-positioned box.
//
export const stories: IStory[] = [
    {
        id: "full-image/default",
        name: "Full Image",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <WithRealAssets count={1}>
                    {assets => (
                        <div style={{ position: "relative", width: "100%", height: "400px" }}>
                            <FullImage asset={assets[0]} />
                        </div>
                    )}
                </WithRealAssets>
            </RealDatabaseProviders>
        ),
    },
];
