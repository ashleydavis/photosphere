import React, { useEffect, useState } from "react";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";
import CircularProgress from "@mui/joy/CircularProgress";
import Box from "@mui/joy/Box";
import { type IDatabaseShareConfig } from "../context/platform-context";

//
// BLE service and characteristic UUIDs — must match the sender in bluetooth-share.ts.
//
const SERVICE_UUID = '0000db51-0000-1000-8000-00805f9b34fb';
const CHAR_UUID = '0000db52-0000-1000-8000-00805f9b34fb';

export interface IReceiveDatabaseBluetoothDialogProps {
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
// Modal dialog that scans for a nearby BLE peripheral advertising the Photosphere
// database share service and reads the config from it using Web Bluetooth.
//
export function ReceiveDatabaseBluetoothDialog({ open, onClose }: IReceiveDatabaseBluetoothDialogProps) {
    //
    // The received database config, once a sender is found.
    //
    const [receivedConfig, setReceivedConfig] = useState<IDatabaseShareConfig | null>(null);

    //
    // True while scanning and reading from the peripheral.
    //
    const [isSearching, setIsSearching] = useState<boolean>(false);

    //
    // Error message if the Bluetooth operation fails.
    //
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        if (open) {
            setReceivedConfig(null);
            setError(null);
            setIsSearching(true);
            receiveConfig();
        }
    }, [open]);

    //
    // Scans for the PhotoSphere BLE peripheral and reads the database config.
    //
    async function receiveConfig() {
        try {
            const nav = navigator as any;
            const device = await nav.bluetooth.requestDevice({
                filters: [{ services: [SERVICE_UUID] }],
            });

            if (!device.gatt) {
                throw new Error('GATT not available on this device');
            }

            const server = await device.gatt.connect();
            const service = await server.getPrimaryService(SERVICE_UUID);
            const characteristic = await service.getCharacteristic(CHAR_UUID);
            const value = await characteristic.readValue();

            const config = JSON.parse(new TextDecoder().decode(value)) as IDatabaseShareConfig;
            setReceivedConfig(config);
            await device.gatt.disconnect();
        }
        catch (err) {
            setError(err instanceof Error ? err.message : String(err));
        }
        finally {
            setIsSearching(false);
        }
    }

    function handleClose() {
        setReceivedConfig(null);
        setError(null);
        setIsSearching(false);
        onClose();
    }

    return (
        <Modal open={open} onClose={handleClose}>
            <ModalDialog sx={{ minWidth: 400 }}>
                <ModalClose />
                <DialogTitle>Receive Database via Bluetooth</DialogTitle>
                <DialogContent>
                    {isSearching
                        && (
                            <Box sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, py: 2 }}>
                                <CircularProgress />
                                <Typography level="body-md">
                                    Scanning for nearby PhotoSphere device...
                                </Typography>
                            </Box>
                        )
                    }
                    {!isSearching && receivedConfig !== null
                        && (
                            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1, py: 1 }}>
                                <Typography level="body-md">
                                    Received database: <strong>{receivedConfig.name}</strong>
                                </Typography>
                                <Box
                                    component="pre"
                                    sx={{ fontFamily: 'monospace', fontSize: 'sm', whiteSpace: 'pre-wrap', wordBreak: 'break-all', mt: 1 }}
                                >
                                    {JSON.stringify(receivedConfig, null, 2)}
                                </Box>
                            </Box>
                        )
                    }
                    {!isSearching && error !== null
                        && (
                            <Box sx={{ py: 2 }}>
                                <Typography level="body-md" color="danger">
                                    {error}
                                </Typography>
                            </Box>
                        )
                    }
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
