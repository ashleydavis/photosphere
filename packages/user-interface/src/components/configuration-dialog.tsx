import React, { useState } from "react";
import Box from "@mui/material/Box";
import ToggleButtonGroup from "@mui/material/ToggleButtonGroup";
import ToggleButton from "@mui/material/ToggleButton";
import Button from "@mui/material/Button";
import Slider from "@mui/material/Slider";
import Switch from "@mui/material/Switch";
import IconButton from "@mui/material/IconButton";
import CloseIcon from "@mui/icons-material/Close";
import { ResponsiveDialog } from "./responsive-dialog";
import DialogTitle from "@mui/material/DialogTitle";
import DialogContent from "@mui/material/DialogContent";
import { useThemeSetting } from "../lib/use-theme-setting";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { useSync } from "../context/sync-context";
import { createDialogKeyHandler } from "../lib/dialog-keys";
import { AutoImportSettings } from "./auto-import-settings";
import { ResetDeviceDialog } from "./reset-device-dialog";
import { DialogIconBadge } from "./dialog-icon-badge";
import { DialogSection, SectionRow } from "./dialog-section";

//
// The theme choices' look: each shows its icon before its name, as the style guide's theme
// choices do.
//
const toggleSx = {
    gap: "var(--space-2)",
};

//
// The switches' look: the row they sit in takes the click, so the switch itself ignores the
// pointer and only shows the setting's state.
//
const switchSx = {
    pointerEvents: "none",
};

export interface IConfigurationDialogProps {
    //
    // Set to true to display the dialog.
    //
    open: boolean;

    //
    // Event raised when the dialog is closed.
    //
    onClose: () => void;
}

//
// Modal dialog for configuring the Photosphere app.
//
export function ConfigurationDialog({ open, onClose }: IConfigurationDialogProps) {
    const [themeSetting, chooseTheme] = useThemeSetting();
    const { targetRowHeight, setTargetRowHeight } = useGalleryLayout();
    const { syncEnabled, toggleSyncEnabled, syncOnlyOnWifi, toggleSyncOnlyOnWifi } = useSync();

    //
    // Whether the reset-device confirmation is open.
    //
    const [resetDialogOpen, setResetDialogOpen] = useState<boolean>(false);

    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={300}
            maxWidth={440}
            dataId="configuration-dialog"
            onKeyDown={createDialogKeyHandler(onClose, false)}
            >
                <IconButton
                    aria-label="Close"
                    data-id="configuration-dialog-close"
                    onClick={onClose}
                    >
                    <CloseIcon />
                </IconButton>
                <DialogTitle>
                    <DialogIconBadge icon={<i className="fa-solid fa-gear" />} danger={false} />
                    Configuration
                </DialogTitle>
                <DialogContent>
                    <Box
                        sx={{
                            display: "flex",
                            flexDirection: "column",
                            gap: "var(--settings-section-gap)",
                            paddingTop: "var(--space-1)",
                        }}
                        >
                        <DialogSection heading="">
                            <SectionRow
                                label="Theme"
                                hint={undefined}
                                control={
                                    <ToggleButtonGroup
                                        exclusive
                                        size="small"
                                        value={themeSetting}
                                        onChange={async (_event, value) => {
                                            if (value) {
                                                const newTheme = value as 'light' | 'dark' | 'system';
                                                await chooseTheme(newTheme);
                                            }
                                        }}
                                        >
                                        <ToggleButton value="light" sx={toggleSx}>
                                            <i className="fa-solid fa-sun" aria-hidden={true} />
                                            Light
                                        </ToggleButton>
                                        <ToggleButton value="dark" sx={toggleSx}>
                                            <i className="fa-solid fa-moon" aria-hidden={true} />
                                            Dark
                                        </ToggleButton>
                                        <ToggleButton value="system" sx={toggleSx}>
                                            <i className="fa-solid fa-circle-half-stroke" aria-hidden={true} />
                                            System
                                        </ToggleButton>
                                    </ToggleButtonGroup>
                                }
                                />
                            <Box
                                sx={{
                                    display: "flex",
                                    flexDirection: "column",
                                    gap: "var(--space-1)",
                                    padding: "var(--space-3)",
                                }}
                                >
                                <span>Photo size</span>
                                <Box
                                    sx={{
                                        display: "flex",
                                        alignItems: "center",
                                        gap: "var(--space-3)",
                                        padding: "0px var(--space-2)",
                                        color: "var(--color-text-muted)",
                                    }}
                                    >
                                    <Box
                                        component="i"
                                        className="fa-solid fa-image"
                                        aria-hidden={true}
                                        sx={{
                                            fontSize: "var(--icon-sm)",
                                        }}
                                        />
                                    <Slider
                                        min={50}
                                        max={500}
                                        value={targetRowHeight}
                                        onChange={(_e, value) => setTargetRowHeight(value as number)}
                                    />
                                    <Box
                                        component="i"
                                        className="fa-solid fa-image"
                                        aria-hidden={true}
                                        sx={{
                                            fontSize: "var(--text-xl)",
                                        }}
                                        />
                                </Box>
                            </Box>
                        </DialogSection>

                        <DialogSection heading="Syncing">
                            <Box
                                data-id="sync-enabled-toggle"
                                onClick={() => toggleSyncEnabled()}
                                sx={{
                                    cursor: "pointer",
                                }}
                                >
                                <SectionRow
                                    label="Enable syncing"
                                    hint={undefined}
                                    control={<Switch readOnly checked={syncEnabled} sx={switchSx} />}
                                    />
                            </Box>
                            <Box
                                data-id="sync-wifi-only-toggle"
                                onClick={() => toggleSyncOnlyOnWifi()}
                                sx={{
                                    cursor: "pointer",
                                }}
                                >
                                <SectionRow
                                    label="Only sync over Wi-Fi"
                                    hint={undefined}
                                    control={<Switch readOnly checked={syncOnlyOnWifi} sx={switchSx} />}
                                    />
                            </Box>
                        </DialogSection>

                        <AutoImportSettings />

                        {/* Last in the dialog: the one setting nobody should land on by accident. */}
                        <DialogSection heading="Reset device">
                            <SectionRow
                                label={
                                    <Box
                                        component="span"
                                        sx={{
                                            color: "var(--color-text-muted)",
                                            fontSize: "var(--text-sm)",
                                        }}
                                        >
                                        Removes the databases Photosphere keeps on this device and the photos
                                        in them, along with its secrets, settings and caches.
                                    </Box>
                                }
                                hint={undefined}
                                control={
                                    <Button
                                        data-id="reset-device-open"
                                        color="error"
                                        variant="outlined"
                                        size="small"
                                        sx={{
                                            flex: "none",
                                        }}
                                        onClick={() => setResetDialogOpen(true)}
                                        >
                                        Reset device
                                    </Button>
                                }
                                />
                        </DialogSection>
                    </Box>
                </DialogContent>

                <ResetDeviceDialog
                    open={resetDialogOpen}
                    onClose={() => setResetDialogOpen(false)}
                />
        </ResponsiveDialog>
    );
}
