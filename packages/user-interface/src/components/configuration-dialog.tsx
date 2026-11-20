import React, { useState } from "react";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
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
                <DialogTitle>Configuration</DialogTitle>
                <DialogContent>
                    <Stack spacing={3} sx={{ maxWidth: 400, pt: 1 }}>
                        <Stack>
                            <Typography variant="caption">Theme</Typography>
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
                                sx={{ mt: 1 }}
                            >
                                <ToggleButton value="light">Light</ToggleButton>
                                <ToggleButton value="dark">Dark</ToggleButton>
                                <ToggleButton value="system">System</ToggleButton>
                            </ToggleButtonGroup>
                        </Stack>

                        <Stack>
                            <Typography variant="caption">Photo size</Typography>
                            <Slider
                                min={50}
                                max={500}
                                value={targetRowHeight}
                                onChange={(_e, value) => setTargetRowHeight(value as number)}
                            />
                        </Stack>

                        <Stack>
                            <Typography variant="caption">Syncing</Typography>
                            <Stack
                                data-id="sync-enabled-toggle"
                                direction="row"
                                onClick={() => toggleSyncEnabled()}
                                sx={{
                                    mt: 1,
                                    cursor: "pointer",
                                    justifyContent: "space-between",
                                    alignItems: "center",
                                }}
                            >
                                <Typography variant="body2">Enable syncing</Typography>
                                <Switch readOnly checked={syncEnabled} sx={{ pointerEvents: "none" }} />
                            </Stack>
                            <Stack
                                data-id="sync-wifi-only-toggle"
                                direction="row"
                                onClick={() => toggleSyncOnlyOnWifi()}
                                sx={{
                                    mt: 1,
                                    cursor: "pointer",
                                    justifyContent: "space-between",
                                    alignItems: "center",
                                }}
                            >
                                <Typography variant="body2">Only sync over Wi-Fi</Typography>
                                <Switch readOnly checked={syncOnlyOnWifi} sx={{ pointerEvents: "none" }} />
                            </Stack>
                        </Stack>

                        <AutoImportSettings />

                        {/* Last in the dialog: the one setting nobody should land on by accident. */}
                        <Stack>
                            <Typography variant="caption">Reset device</Typography>
                            <Typography variant="body2" sx={{ mt: 1 }}>
                                Removes the databases Photosphere keeps on this device and the photos
                                in them, along with its secrets, settings and caches.
                            </Typography>
                            <Button
                                data-id="reset-device-open"
                                color="error"
                                variant="outlined"
                                sx={{ mt: 1 }}
                                onClick={() => setResetDialogOpen(true)}
                            >
                                Reset device
                            </Button>
                        </Stack>
                    </Stack>
                </DialogContent>

                <ResetDeviceDialog
                    open={resetDialogOpen}
                    onClose={() => setResetDialogOpen(false)}
                />
        </ResponsiveDialog>
    );
}
