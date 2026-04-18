import React, { useEffect, useRef, useState } from "react";
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
    // True while the scan loop is running.
    //
    const [isScanning, setIsScanning] = useState<boolean>(false);

    //
    // Number of scan attempts made so far.
    //
    const [attempts, setAttempts] = useState<number>(0);

    //
    // Fatal error that stops scanning.
    //
    const [fatalError, setFatalError] = useState<string | null>(null);

    //
    // Ref that stays true while the dialog is open, used to stop the scan loop on close.
    //
    const scanningRef = useRef<boolean>(false);

    useEffect(() => {
        if (open) {
            setReceivedConfig(null);
            setFatalError(null);
            setAttempts(0);
            setIsScanning(true);
            scanningRef.current = true;
            scanLoop();
        }
        else {
            scanningRef.current = false;
        }
    }, [open]);

    //
    // Continuously scans for the PhotoSphere BLE peripheral until found or the dialog is closed.
    //
    async function scanLoop() {
        while (scanningRef.current) {
            try {
                const nav = navigator as any;
                const device = await nav.bluetooth.requestDevice({
                    filters: [{ services: [SERVICE_UUID] }],
                });

                const server = await device.gatt.connect();
                const service = await server.getPrimaryService(SERVICE_UUID);
                const characteristic = await service.getCharacteristic(CHAR_UUID);
                const value = await characteristic.readValue();

                const config = JSON.parse(new TextDecoder().decode(value)) as IDatabaseShareConfig;
                scanningRef.current = false;
                setIsScanning(false);
                setReceivedConfig(config);
                return;
            }
            catch (err) {
                const message = err instanceof Error ? err.message : String(err);
                const isNoDeviceFound = message.includes('User cancelled') || message.includes('chooser');
                if (isNoDeviceFound) {
                    setAttempts(prev => prev + 1);
                    await new Promise<void>(resolve => setTimeout(resolve, 2000));
                }
                else {
                    scanningRef.current = false;
                    setIsScanning(false);
                    setFatalError(message);
                    return;
                }
            }
        }
        setIsScanning(false);
    }

    function handleClose() {
        scanningRef.current = false;
        setReceivedConfig(null);
        setIsScanning(false);
        setFatalError(null);
        onClose();
    }

    return (
        <Modal open={open} onClose={handleClose}>
            <ModalDialog sx={{ minWidth: 400 }}>
                <ModalClose />
                <DialogTitle>Receive Database via Bluetooth</DialogTitle>
                <DialogContent>
                    {isScanning
                        && (
                            <Box sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, py: 2 }}>
                                <CircularProgress />
                                <Typography level="body-md">
                                    Scanning for nearby PhotoSphere device...
                                </Typography>
                                {attempts > 0
                                    && (
                                        <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                                            {attempts} attempt{attempts !== 1 ? 's' : ''} — make sure the sender is running on the other device.
                                        </Typography>
                                    )
                                }
                            </Box>
                        )
                    }
                    {!isScanning && fatalError !== null
                        && (
                            <Box sx={{ py: 2 }}>
                                <Typography level="body-md" color="danger">
                                    {fatalError}
                                </Typography>
                            </Box>
                        )
                    }
                    {!isScanning && receivedConfig !== null
                        && (
                            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1, py: 1 }}>
                                <Typography level="body-md" color="success">
                                    Database received successfully.
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
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
