import React from "react";
import { useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import Stack from "@mui/joy/Stack/Stack";
import Typography from "@mui/joy/Typography";
import ToggleButtonGroup from "@mui/joy/ToggleButtonGroup/ToggleButtonGroup";
import Button from "@mui/joy/Button/Button";
import Slider from "@mui/joy/Slider/Slider";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import { useConfig } from "../context/config-context";
import { useGalleryLayout } from "../context/gallery-layout-context";

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

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog>
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
                    </Stack>
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
