import React, { useEffect, useState } from "react";
import { NavLink, useLocation, useNavigate } from "react-router-dom";
import { Spinner } from "./spinner";
import IconButton from '@mui/material/IconButton';
import Button from '@mui/material/Button';
import Box from '@mui/material/Box';
import useMediaQuery from '@mui/material/useMediaQuery';
import ArrowCircleUp from "@mui/icons-material/ArrowCircleUp";
import MoreVert from '@mui/icons-material/MoreVert';
import Star from "@mui/icons-material/Star";
import StarBorder from "@mui/icons-material/StarBorder";
import FileUpload from "@mui/icons-material/FileUpload";
import Menu from "@mui/icons-material/Menu";
import Search from "@mui/icons-material/Search";
import PhotoLibrary from "@mui/icons-material/PhotoLibrary";
import Map from "@mui/icons-material/Map";
import OutlinedInput from "@mui/material/OutlinedInput";
import type { SxProps, Theme } from "@mui/material/styles";
import { useSearch } from "../context/search-context";
import { useIsMobile } from "../lib/use-is-mobile";
import { useDebounce } from "../lib/use-debounce";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useToast } from "../context/toast-context";
import { usePlatform } from "../context/platform-context";
import { ThemeToggle } from "./theme-toggle";
import { NavbarJobsIndicator } from "./navbar-jobs-indicator";
import { findTemporaryNavPage } from "../lib/nav-pages";

export interface INavbarProps {
    //
    // Set to true to open the sidebar.
    //
    sidebarOpen: boolean;

    //
    // Sets the sidebar open or closed.
    //
    setSidebarOpen: (open: boolean) => void;

    //
    // Opens the configuration dialog.
    //
    onOpenConfiguration: () => void;

    //
    // Opens the right sidebar.
    //
    setRightSidebarOpen: (open: boolean) => void;
}

//
// The look of a page button in the desktop navbar, from the navbar tab tokens: muted text with no
// fill, running the full height of the bar so the open page's line sits along its foot.
//
const PAGE_BUTTON_SX = {
    flex: "none",
    alignSelf: "stretch",
    minWidth: "var(--button-height-md)",
    minHeight: 0,
    padding: "var(--navbar-button-padding)",
    gap: "var(--navbar-tab-gap)",
    color: "var(--color-navbar-tab-text)",
    fontSize: "var(--navbar-tab-label-size)",
    borderRadius: "var(--navbar-tab-radius)",
    boxShadow: "inset 0 0 0 1px var(--color-navbar-tab-border)",
    whiteSpace: "nowrap",
    "& .MuiSvgIcon-root": {
        fontSize: "var(--icon-md)",
    },
};

//
// The page buttons on a desktop window too narrow for each label beside its icon: the label
// stacks under the icon in the tab bar's smaller size, as the style guide asks.
//
const STACKED_PAGE_BUTTON_SX = {
    flexDirection: "column",
    gap: "var(--space-1)",
    padding: "0 var(--space-3)",
    fontSize: "var(--text-xs)",
};

//
// The look the open page's button takes, from the navbar's current-page tokens: its fill, its
// text, the ring round its edge and the line along its foot.
//
const CURRENT_PAGE_BUTTON_SX = {
    backgroundColor: "var(--color-navbar-current-bg)",
    color: "var(--color-navbar-current-text)",
    boxShadow: "inset 0 0 0 1px var(--color-navbar-current-ring), inset 0 var(--navbar-current-line-y) 0 0 var(--color-navbar-current-line)",
    "&:hover": {
        backgroundColor: "var(--color-navbar-current-bg)",
        color: "var(--color-navbar-current-text)",
    },
};

//
// The look of an icon button for the open page or the open search on a mobile, where the
// button has no label: a tinted fill inside a ring, as any current icon button.
//
const CURRENT_ICON_BUTTON_SX = {
    backgroundColor: "var(--color-nav-current-bg)",
    color: "var(--color-nav-current-text)",
    borderColor: "var(--color-nav-current-text)",
    "&:hover": {
        backgroundColor: "var(--color-nav-current-bg)",
        color: "var(--color-nav-current-text)",
    },
};

//
// The look of the photo count, from the navbar's chip tokens, so it matches the jobs chip beside
// it and can differ from the chips on a photo.
//
const PHOTO_COUNT_SX = {
    display: "inline-flex",
    alignItems: "center",
    gap: "var(--space-1)",
    minHeight: "var(--button-height-sm)",
    padding: "0 var(--space-3)",
    cursor: "pointer",
    whiteSpace: "nowrap",
    fontFamily: "var(--font-sans)",
    fontSize: "var(--text-sm)",
    color: "var(--color-navbar-chip-text)",
    backgroundColor: "var(--color-navbar-chip-bg)",
    border: "1px solid var(--color-navbar-chip-border)",
    borderRadius: "var(--radius-chip)",
    transition: "background-color var(--duration-fast) var(--ease-standard)",
    "&:hover": {
        backgroundColor: "var(--color-hover)",
    },
    "&:focus-visible": {
        outline: "var(--focus-ring-width) solid var(--color-focus)",
        outlineOffset: "var(--focus-ring-offset)",
    },
    "& .MuiSvgIcon-root": {
        fontSize: "var(--icon-sm)",
    },
};

//
// The look of the update pill, from the navbar's update tokens: filled in the success colour, as
// the one piece of good news in the navbar.
//
const UPDATE_PILL_SX = {
    display: "inline-flex",
    alignItems: "center",
    gap: "var(--space-1)",
    minHeight: "var(--button-height-sm)",
    padding: "0 var(--space-3)",
    whiteSpace: "nowrap",
    fontSize: "var(--text-sm)",
    fontWeight: "var(--weight-bold)",
    color: "var(--color-navbar-update-text)",
    backgroundColor: "var(--color-navbar-update-bg)",
    borderRadius: "var(--radius-full)",
    textDecoration: "none",
    "& .MuiSvgIcon-root": {
        fontSize: "var(--icon-sm)",
    },
};

//
// The navbar component for the Photosphere app.
//
export function Navbar({
    sidebarOpen,
    setSidebarOpen,
    setRightSidebarOpen,
    onOpenConfiguration,
}: INavbarProps) {
    const { openSearch, setOpenSearch, searchInput, onCommitSearch, onCloseSearch, savedSearches, saveSearch, unsaveSearch } = useSearch();

    //
    // Drives the mobile layout of the bar: icon-only controls, sized and spaced for a thumb.
    //
    const isMobile = useIsMobile();

    //
    // Stacks the desktop page buttons' labels under their icons on a window too narrow to show
    // them side by side, as the style guide's navbar does below 900px.
    //
    const isStacked = useMediaQuery("(max-width: 899px)");

    //
    // Sizing shared by every icon button in the bar: a square of the large button height on a
    // mobile, the smallest comfortable touch target, and of the medium height on desktop.
    //
    const iconButtonSx = isMobile
        ? {
            width: "var(--button-height-lg)",
            height: "var(--button-height-lg)",
        }
        : {
            width: "var(--button-height-md)",
            height: "var(--button-height-md)",
        };

    //
    // The look of a desktop page button, with its label stacked under its icon when the window
    // is narrow, and marked when it is the open page.
    //
    function pageButtonSx(isCurrent: boolean): SxProps<Theme> {
        return [
            PAGE_BUTTON_SX,
            isStacked ? STACKED_PAGE_BUTTON_SX : {},
            isCurrent ? CURRENT_PAGE_BUTTON_SX : {},
        ];
    }

    //
    // Local input state so keystrokes don't re-render all context consumers.
    //
    const [draftSearchInput, setLocalInput] = useState<string>(searchInput);

    //
    // Debounce helper for the search input.
    //
    const searchDebounce = useDebounce(500);

    //
    // Sync local input when searchInput changes externally (e.g., search triggered from sidebar).
    //
    useEffect(() => {
        setLocalInput(searchInput);
    }, [searchInput]);

    //
    // The latest available release version, when newer than the running build.
    //
    const [updateVersion, setUpdateVersion] = useState<string | undefined>(undefined);

    const { addToast } = useToast();
    const platform = usePlatform();

    //
    // Subscribe to update-available IPC events fired by the desktop main process.
    // The main process handles the GitHub fetch and the comparison against the running
    // build, so the renderer only sees this callback when there is a genuinely new
    // version to announce. We (a) show the persistent pill rendered further down, and
    // (b) fire a one-off primary-coloured toast so the user notices on startup. The
    // version is persisted in `last_shown_update_version` only when the user clicks
    // the toast's close button (via `markUpdateAsShown`); closing the app without
    // dismissing causes the notification to re-fire next startup. On web/mobile this
    // never fires (no main process); update flow there is via the host store.
    //
    useEffect(() => {
        const unsubscribe = platform.onUpdateAvailable(({ latestVersion }) => {
            setUpdateVersion(latestVersion);
            addToast({
                message: `A new version of Photosphere is available: v${latestVersion}`,
                color: 'primary',
                duration: 0,
                action: {
                    label: 'Download',
                    onClick: () => window.open('https://github.com/ashleydavis/photosphere/releases/latest', '_blank', 'noopener'),
                },
                onDismiss: () => {
                    platform.markUpdateAsShown(latestVersion);
                },
            });
        });
        return unsubscribe;
    }, [platform, addToast]);
    const { sortedItems, selectedItems, clearMultiSelection } = useGallery();
    const { isLoading, isSyncing, databasePath } = useAssetDatabase();

    const sortedItemsCount = sortedItems().length;
    const selectedItemsCount = selectedItems.size;

    // The current location, used to show a temporary nav entry for pages that
    // have no permanent navbar link.
    const location = useLocation();
    const navigate = useNavigate();
    const temporaryNavPage = findTemporaryNavPage(location.pathname, ["/gallery", "/map", "/import"]);
    const TemporaryNavPageIcon = temporaryNavPage?.icon;

    const isGalleryCurrent = location.pathname === "/gallery" || location.pathname.startsWith("/gallery/");
    const isMapCurrent = location.pathname === "/map" || location.pathname.startsWith("/map/");
    const isImportCurrent = location.pathname === "/import" || location.pathname.startsWith("/import/");

    //
    // The navbar sits above the page so its shadow falls on the page, and below the sidebars and
    // the dialogs, which MUI puts at higher layers.
    //
    return (
        <div
            id="navbar"
            className="select-none relative flex-none"
            style={{
                zIndex: 30,
                backgroundColor: "var(--color-navbar-bg)",
                color: "var(--color-text)",
                borderBottom: "1px solid var(--color-navbar-border)",
                boxShadow: "var(--shadow-navbar)",
            }}
        >
            <div className="flex flex-col">
                {/* The bar's controls are touch-sized squares with real gaps between them on a
                    mobile. On desktop the page buttons run the full height of the bar, so the open
                    page's line sits along its foot. */}
                <div
                    className="flex flex-row items-center"
                    style={{
                        height: isMobile ? "calc(var(--button-height-lg) + var(--space-4))" : "calc(var(--button-height-md) + var(--space-4))",
                        gap: isMobile ? "var(--space-1)" : "var(--space-2)",
                        padding: isMobile ? "0 var(--space-2)" : "0 var(--space-4)",
                    }}
                >
                    <IconButton
                        data-id="sidebar-toggle-button"
                        color="default"
                        title="Toggle sidebar"
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                        sx={iconButtonSx}
                    >
                        <Menu fontSize="inherit" />
                    </IconButton>

                    {/* Everything between the two sidebar buttons scrolls sideways when it does not
                        fit, so neither button can be pushed off the screen. See .navbar-scroll. */}
                    <div
                        className="navbar-scroll flex flex-row items-center self-stretch"
                        style={{
                            gap: isMobile ? "var(--space-1)" : "var(--space-2)",
                        }}
                    >

                    {!isMobile
                        && <div
                            className="flex items-center"
                            style={{
                                gap: "var(--space-2)",
                                marginLeft: "var(--space-1)",
                                marginRight: "var(--space-3)",
                            }}
                        >
                            <span
                                aria-hidden={true}
                                className="flex items-center justify-center"
                                style={{
                                    width: "var(--space-6)",
                                    height: "var(--space-6)",
                                    borderRadius: "var(--radius-sm)",
                                    background: "var(--empty-icon-bg)",
                                    color: "var(--color-empty-icon)",
                                    fontSize: "var(--icon-sm)",
                                }}
                            >
                                <PhotoLibrary fontSize="inherit" />
                            </span>
                            <h1
                                style={{
                                    margin: 0,
                                    fontFamily: "var(--font-heading)",
                                    fontSize: "var(--text-lg)",
                                    fontWeight: "var(--weight-bold)",
                                    whiteSpace: "nowrap",
                                }}
                            >
                                Photosphere
                            </h1>
                        </div>
                    }

                    {isMobile
                        && <IconButton
                            color="default"
                            title="Search"
                            aria-current={openSearch ? "page" : undefined}
                            onClick={() => {
                                navigate("/gallery");
                                setOpenSearch(true);
                            }}
                            sx={[
                                iconButtonSx,
                                openSearch ? CURRENT_ICON_BUTTON_SX : {},
                            ]}
                        >
                            <Search fontSize="inherit" />
                        </IconButton>
                    }

                    {!isMobile
                        && <>
                            <Button
                                variant="text"
                                title="Search"
                                aria-current={openSearch ? "page" : undefined}
                                onClick={() => {
                                    navigate("/gallery");
                                    setOpenSearch(true);
                                }}
                                sx={pageButtonSx(openSearch)}
                            >
                                <Search />
                                <span>Search</span>
                            </Button>

                            <Button
                                variant="text"
                                component={NavLink}
                                to="/gallery"
                                title="Gallery"
                                sx={pageButtonSx(isGalleryCurrent)}
                            >
                                <PhotoLibrary />
                                <span>Gallery</span>
                            </Button>

                            <Button
                                variant="text"
                                component={NavLink}
                                to="/map"
                                title="Map"
                                sx={pageButtonSx(isMapCurrent)}
                            >
                                <Map />
                                <span>Map</span>
                            </Button>

                            {databasePath && (
                                <Button
                                    variant="text"
                                    component={NavLink}
                                    to="/import"
                                    title="Import"
                                    data-id="navbar-import-button"
                                    sx={pageButtonSx(isImportCurrent)}
                                >
                                    <FileUpload />
                                    <span>Import</span>
                                </Button>
                            )}
                        </>
                    }

                    {temporaryNavPage && TemporaryNavPageIcon && (
                        isMobile
                            ? <IconButton
                                component={NavLink}
                                to={temporaryNavPage.path}
                                title={temporaryNavPage.label}
                                sx={[
                                    iconButtonSx,
                                    CURRENT_ICON_BUTTON_SX,
                                ]}
                            >
                                <TemporaryNavPageIcon fontSize="inherit" />
                            </IconButton>
                            : <Button
                                variant="text"
                                component={NavLink}
                                to={temporaryNavPage.path}
                                title={temporaryNavPage.label}
                                sx={pageButtonSx(true)}
                            >
                                <TemporaryNavPageIcon />
                                <span>{temporaryNavPage.label}</span>
                            </Button>
                    )}

                    <div className="ml-auto"></div>

                    {(isLoading)
                        && <div
                            className="flex flex-row items-center"
                            style={{
                                gap: "var(--space-2)",
                                fontSize: "var(--text-sm)",
                                color: "var(--color-text-muted)",
                            }}
                        >
                            {!isMobile && <span>Loading</span>}
                            <Spinner show={true} />
                        </div>
                    }

                    <NavbarJobsIndicator />


                    {databasePath && (
                        <div className="flex flex-row items-center">
                            {selectedItemsCount > 0
                                && <div
                                    className="flex flex-row items-center"
                                    style={{
                                        gap: "var(--space-1)",
                                    }}
                                >
                                    <IconButton
                                        size="small"
                                        title="Clear selection"
                                        onClick={clearMultiSelection}
                                        sx={{
                                            "& i": {
                                                color: "inherit",
                                            },
                                        }}
                                    >
                                        <i className="fa-solid fa-close"></i>
                                    </IconButton>
                                    <span
                                        className="flex items-center"
                                        style={{
                                            minHeight: "var(--button-height-sm)",
                                            padding: "0 var(--space-3)",
                                            whiteSpace: "nowrap",
                                            fontSize: "var(--text-sm)",
                                            fontWeight: "var(--weight-bold)",
                                            color: "var(--color-on-accent)",
                                            backgroundColor: "var(--color-accent)",
                                            borderRadius: "var(--radius-chip)",
                                        }}
                                    >
                                        {selectedItemsCount} selected
                                    </span>
                                </div>
                                /*
                                    A real <button> carrying the data-id, because the smoke-test
                                    driver clicks the element carrying the data-id and several tests
                                    read the count from that same element. The pill below is drawn
                                    like the jobs indicator's chip beside it, so the two match.
                                */
                                || <Box
                                    component="button"
                                    data-id="database-photo-count"
                                    title="Show database summary"
                                    onClick={() => window.dispatchEvent(new CustomEvent("photosphere:show-database-summary"))}
                                    sx={PHOTO_COUNT_SX}
                                    >
                                    <PhotoLibrary />
                                    {sortedItemsCount} photos
                                </Box>
                            }
                        </div>
                    )}

                    {updateVersion && (
                        <Box
                            component="a"
                            data-id="update-available-badge"
                            href="https://github.com/ashleydavis/photosphere/releases/latest"
                            target="_blank"
                            rel="noreferrer"
                            title="A new version of Photosphere is available"
                            sx={UPDATE_PILL_SX}
                        >
                            <ArrowCircleUp />
                            v{updateVersion} available
                        </Box>
                    )}

                    <ThemeToggle />

                    </div>

                    {/*
                        Machine-readable sync state for the smoke tests: the driver reads this data-id to
                        assert the navbar reflects a running background sync ("syncing") and its return to
                        rest ("idle"). It always renders so the value is never empty, and it is taken
                        off-screen (rather than display:none, which the driver treats as absent) so it adds
                        no visible chrome while staying present in the DOM. It sits outside the scrolling
                        middle so it can never contribute to that region's scroll width.
                    */}
                    <span
                        data-id="navbar-sync-state"
                        style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' }}
                    >
                        {isSyncing ? "syncing" : "idle"}
                    </span>

                    <IconButton
                        data-id="right-sidebar-button"
                        sx={iconButtonSx}
                        color="default"
                        title="Open menu"
                        onClick={() => setRightSidebarOpen(true)}
                    >
                        <MoreVert fontSize="inherit" />
                    </IconButton>
                </div>

                {openSearch
                    && <div
                        className="flex flex-row items-center"
                        style={{
                            gap: isMobile ? "var(--space-1)" : "var(--space-2)",
                            padding: isMobile ? "var(--space-2)" : "var(--space-2) var(--space-4)",
                            backgroundColor: "var(--color-toolbar-bg)",
                            borderTop: "1px solid var(--color-toolbar-border)",
                        }}
                    >
                        <i
                            className="fa-solid fa-search"
                            style={{
                                color: "var(--color-text-muted)",
                                fontSize: "var(--icon-md)",
                                marginRight: "var(--space-1)",
                            }}
                        ></i>
                        <OutlinedInput
                            size="small"
                            autoFocus
                            className="flex-grow"
                            placeholder="Type to search..."
                            value={draftSearchInput}
                            onChange={event => {
                                const value = event.target.value;
                                setLocalInput(value);
                                searchDebounce.schedule(() => onCommitSearch(value));
                            }}
                            onKeyDown={async event => {
                                if (event.key === "Enter") {
                                    //
                                    // Commits the search immediately, cancelling any pending debounce.
                                    //
                                    searchDebounce.cancel();
                                    await onCommitSearch(draftSearchInput);
                                }
                                else if (event.key === "Escape") {
                                    //
                                    // Cancels the search.
                                    //
                                    searchDebounce.cancel();
                                    await onCloseSearch();
                                }
                            }}
                        />
                        {draftSearchInput.trim().length > 0 && (
                            <IconButton
                                color="default"
                                title={savedSearches.includes(draftSearchInput.trim()) ? "Unsave search" : "Save search"}
                                onClick={async () => {
                                    if (savedSearches.includes(draftSearchInput.trim())) {
                                        await unsaveSearch(draftSearchInput.trim());
                                    }
                                    else {
                                        await saveSearch(draftSearchInput.trim());
                                    }
                                }}
                                sx={savedSearches.includes(draftSearchInput.trim())
                                    ? {
                                        color: "var(--color-accent)",
                                        borderColor: "var(--color-accent)",
                                    }
                                    : undefined
                                }
                            >
                                {savedSearches.includes(draftSearchInput.trim())
                                    ? <Star fontSize="inherit" />
                                    : <StarBorder fontSize="inherit" />
                                }
                            </IconButton>
                        )}
                        <IconButton
                            component="a"
                            href="https://github.com/ashleydavis/photosphere/wiki/Gallery-Search"
                            target="_blank"
                            rel="noreferrer"
                            title="Search help"
                            sx={{
                                "& i": {
                                    color: "inherit",
                                },
                            }}
                        >
                            <i className="fa-solid fa-circle-question"></i>
                        </IconButton>
                        <IconButton
                            title="Close search"
                            onClick={() => {
                                searchDebounce.cancel();
                                onCloseSearch();
                            }}
                            sx={{
                                "& i": {
                                    color: "inherit",
                                },
                            }}
                        >
                            <i className="fa-solid fa-close"></i>
                        </IconButton>
                    </div>
                }
            </div>

        </div>
    );
}
