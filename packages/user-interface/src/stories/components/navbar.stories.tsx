import React from "react";
import { Navbar } from "../../components/navbar";
import { MobileTabBar } from "../../components/mobile-tab-bar";
import { useIsMobile } from "../../lib/use-is-mobile";
import { MockProviders, mockAssetDatabase, mockAssets, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Renders the app's frame as main.tsx lays it out: the navbar across the top, an empty page area
// under it and, on a mobile, the tab bar at the foot of the screen, so the stories show where the
// page buttons go at each size.
//
function NavbarFrame() {
    const isMobile = useIsMobile();

    return (
        <div className="flex flex-col h-full">
            <Navbar
                sidebarOpen={false}
                setSidebarOpen={noOp}
                setRightSidebarOpen={noOp}
                onOpenConfiguration={noOp}
                />
            <div
                className="flex-1"
                style={{
                    backgroundColor: "var(--color-bg)",
                }}
                />
            {isMobile && <MobileTabBar />}
        </div>
    );
}

//
// Stories for the Navbar.
//
export const stories: IStory[] = [
    {
        id: "navbar/default",
        name: "Navbar",
        category: "Components",
        render: () => (
            <MockProviders>
                <Navbar
                    sidebarOpen={false}
                    setSidebarOpen={noOp}
                    setRightSidebarOpen={noOp}
                    onOpenConfiguration={noOp}
                    />
            </MockProviders>
        ),
    },
    {
        id: "navbar/frame",
        name: "Navbar and tab bar",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(mockAssets(50))}>
                <NavbarFrame />
            </MockProviders>
        ),
    },
];
