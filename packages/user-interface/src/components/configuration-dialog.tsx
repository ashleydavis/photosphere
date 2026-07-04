import React from "react";
import { useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import Stack from "@mui/joy/Stack/Stack";
import Typography from "@mui/joy/Typography";
import ToggleButtonGroup from "@mui/joy/ToggleButtonGroup/ToggleButtonGroup";
import Button from "@mui/joy/Button/Button";
import Slider from "@mui/joy/Slider/Slider";
import Switch from "@mui/joy/Switch";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import { responsiveModalSx } from "../lib/modal-styles";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import { useConfig } from "../context/config-context";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { useSync } from "../context/sync-context";
import { createDialogKeyHandler } from "../lib/dialog-keys";

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
    const { mode, setMode } = useColorScheme();
    const config = useConfig();
    const { targetRowHeight, setTargetRowHeight } = useGalleryLayout();
    const { syncEnabled, toggleSyncEnabled, syncOnlyOnWifi, toggleSyncOnlyOnWifi } = useSync();

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog data-id="configuration-dialog" onKeyDown={createDialogKeyHandler(onClose, false)} sx={{ ...responsiveModalSx(300, 440) }}>
                <ModalClose />
                <DialogTitle>Configuration</DialogTitle>
                <DialogContent>
                    <Stack spacing={3} sx={{ maxWidth: 400, pt: 1 }}>
                        <Stack>
                            <Typography level="body-xs">Theme</Typography>
                            <ToggleButtonGroup
                                value={mode}
                                onChange={async (_event, value) => {
                                    if (value) {
                                        const newTheme = value as 'light' | 'dark' | 'system';
                                        setMode(newTheme);
                                        await config.set("theme", newTheme);
                                    }
                                }}
                                sx={{ mt: 1 }}
                            >
                                <Button value="light">Light</Button>
                                <Button value="dark">Dark</Button>
                                <Button value="system">System</Button>
                            </ToggleButtonGroup>
                        </Stack>

                        <Stack>
                            <Typography level="body-xs">Photo size</Typography>
                            <Slider
                                min={50}
                                max={500}
                                value={targetRowHeight}
                                onChange={(_e, value) => setTargetRowHeight(value as number)}
                            />
                        </Stack>

                        <Stack>
                            <Typography level="body-xs">Syncing</Typography>
                            <Stack
                                data-id="sync-enabled-toggle"
                                direction="row"
                                justifyContent="space-between"
                                alignItems="center"
                                onClick={() => toggleSyncEnabled()}
                                sx={{ mt: 1, cursor: "pointer" }}
                            >
                                <Typography level="body-sm">Enable syncing</Typography>
                                <Switch readOnly checked={syncEnabled} sx={{ pointerEvents: "none" }} />
                            </Stack>
                            <Stack
                                data-id="sync-wifi-only-toggle"
                                direction="row"
                                justifyContent="space-between"
                                alignItems="center"
                                onClick={() => toggleSyncOnlyOnWifi()}
                                sx={{ mt: 1, cursor: "pointer" }}
                            >
                                <Typography level="body-sm">Only sync over Wi-Fi</Typography>
                                <Switch readOnly checked={syncOnlyOnWifi} sx={{ pointerEvents: "none" }} />
                            </Stack>
                        </Stack>
                    </Stack>
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
