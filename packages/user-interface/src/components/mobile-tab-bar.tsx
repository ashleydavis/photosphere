//
// The tab bar at the foot of the screen on a mobile, holding the navbar's page buttons where a
// thumb reaches them, as the style guide lays out a mobile frame.
//

import React from "react";
import { useLocation, useNavigate } from "react-router-dom";
import BottomNavigation from "@mui/material/BottomNavigation";
import BottomNavigationAction from "@mui/material/BottomNavigationAction";
import PhotoLibrary from "@mui/icons-material/PhotoLibrary";
import Map from "@mui/icons-material/Map";
import FileUpload from "@mui/icons-material/FileUpload";
import { useAssetDatabase } from "../context/asset-database-source";

//
// The look of each tab, from the tab bar tokens: a muted icon with its label under it, and the
// open page's tab in the accent colour with a line along its top.
//
const TAB_SX = {
    minWidth: 0,
    gap: "var(--space-1)",
    color: "var(--color-text-muted)",
    fontFamily: "var(--font-sans)",
    "& .MuiBottomNavigationAction-label": {
        display: "var(--tab-bar-label-display)",
        fontSize: "var(--text-xs)",
    },
    "& .MuiBottomNavigationAction-label.Mui-selected": {
        display: "var(--tab-bar-current-label-display)",
        fontSize: "var(--text-xs)",
        fontWeight: "var(--weight-bold)",
    },
    "&.Mui-selected": {
        color: "var(--color-accent)",
        boxShadow: "inset 0 var(--tab-bar-line-height) 0 0 var(--color-accent)",
    },
    "& .MuiSvgIcon-root": {
        fontSize: "var(--tab-bar-icon-size)",
    },
    "&.Mui-selected .MuiSvgIcon-root": {
        color: "var(--color-tab-bar-current-icon)",
    },
};

//
// Returns the tab of the page open at `pathname`, or false when the open page has no tab, so
// no tab shows as picked.
//
export function currentTab(pathname: string): string | false {
    for (const path of ["/gallery", "/map", "/import"]) {
        if (pathname === path || pathname.startsWith(path + "/")) {
            return path;
        }
    }
    return false;
}

//
// Renders the tab bar with Gallery, Map and, while a database is open, Import, the same page
// buttons the desktop navbar holds. Picking a tab opens its page.
//
export function MobileTabBar() {
    const location = useLocation();
    const navigate = useNavigate();
    const { databasePath } = useAssetDatabase();

    return (
        <BottomNavigation
            showLabels={true}
            value={currentTab(location.pathname)}
            onChange={(_event, path: string) => navigate(path)}
            className="flex-none select-none"
            style={{
                height: "calc(var(--space-8) * 2)",
                background: "var(--color-toolbar-bg)",
                borderTop: "1px solid var(--color-border)",
            }}
        >
            <BottomNavigationAction
                value="/gallery"
                label="Gallery"
                title="Gallery"
                icon={<PhotoLibrary />}
                sx={TAB_SX}
            />
            <BottomNavigationAction
                value="/map"
                label="Map"
                title="Map"
                icon={<Map />}
                sx={TAB_SX}
            />
            {databasePath && (
                <BottomNavigationAction
                    value="/import"
                    label="Import"
                    title="Import"
                    data-id="navbar-import-button"
                    icon={<FileUpload />}
                    sx={TAB_SX}
                />
            )}
        </BottomNavigation>
    );
}
