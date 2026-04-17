import React, { useEffect } from "react";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";
import CircularProgress from "@mui/joy/CircularProgress";
import Box from "@mui/joy/Box";
import { usePlatform, type IDatabaseShareConfig } from "../context/platform-context";

//
// The example database config to share (mirrors docs/example-database-config.json).
//
const DATABASE_SHARE_CONFIG: IDatabaseShareConfig = {
    name: "My Photos",
    path: "s3:my-bucket/photos",
    storage: {
        endpoint: "https://s3.amazonaws.com",
        region: "us-east-1",
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    },
    passPhrase: "maple drift anchor tunnel velvet gross frog orbit plank siren amber cloud",
};

export interface IShareDatabaseBluetoothDialogProps {
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
// Modal dialog that advertises the database config as a BLE GATT peripheral
// for a nearby device to connect to and receive.
//
export function ShareDatabaseBluetoothDialog({ open, onClose }: IShareDatabaseBluetoothDialogProps) {
    const platform = usePlatform();

    useEffect(() => {
        if (open) {
            platform.startBluetoothShare(DATABASE_SHARE_CONFIG);
        }
        return () => {
            if (open) {
                platform.stopBluetoothShare();
            }
        };
    }, [open, platform]);

    function handleClose() {
        platform.stopBluetoothShare();
        onClose();
    }

    return (
        <Modal open={open} onClose={handleClose}>
            <ModalDialog>
                <ModalClose />
                <DialogTitle>Share Database via Bluetooth</DialogTitle>
                <DialogContent>
                    <Box sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, py: 2 }}>
                        <CircularProgress />
                        <Typography level="body-md">
                            Sharing <strong>{DATABASE_SHARE_CONFIG.name}</strong>
                        </Typography>
                        <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                            Waiting for a nearby device to connect via Bluetooth...
                        </Typography>
                    </Box>
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
