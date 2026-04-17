import React, { useEffect, useState } from "react";
import Modal from "@mui/joy/Modal";
import ModalClose from "@mui/joy/ModalClose";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import Typography from "@mui/joy/Typography";
import CircularProgress from "@mui/joy/CircularProgress";
import Box from "@mui/joy/Box";
import { usePlatform, type IDatabaseShareConfig } from "../context/platform-context";

export interface IReceiveDatabaseDialogProps {
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
// Modal dialog that listens for a database config broadcast on the local network
// and displays the received details when found.
//
export function ReceiveDatabaseDialog({ open, onClose }: IReceiveDatabaseDialogProps) {
    const platform = usePlatform();

    //
    // The received database config, once a sender is found.
    //
    const [receivedConfig, setReceivedConfig] = useState<IDatabaseShareConfig | null>(null);

    //
    // True while waiting for a sender to be found.
    //
    const [isSearching, setIsSearching] = useState<boolean>(false);

    useEffect(() => {
        if (open) {
            setReceivedConfig(null);
            setIsSearching(true);
            platform.startDatabaseReceive().then((config) => {
                setIsSearching(false);
                setReceivedConfig(config);
            });
        }
    }, [open, platform]);

    function handleClose() {
        if (isSearching) {
            platform.cancelDatabaseReceive();
        }
        setReceivedConfig(null);
        setIsSearching(false);
        onClose();
    }

    return (
        <Modal open={open} onClose={handleClose}>
            <ModalDialog sx={{ minWidth: 400 }}>
                <ModalClose />
                <DialogTitle>Receive Database via Network</DialogTitle>
                <DialogContent>
                    {isSearching
                        && (
                            <Box sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, py: 2 }}>
                                <CircularProgress />
                                <Typography level="body-md">
                                    Searching for shared databases...
                                </Typography>
                                <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                                    Make sure the other device is sharing a database on the same network.
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
                    {!isSearching && receivedConfig === null
                        && (
                            <Box sx={{ py: 2 }}>
                                <Typography level="body-md" sx={{ color: 'text.tertiary' }}>
                                    No database received (timed out or cancelled).
                                </Typography>
                            </Box>
                        )
                    }
                </DialogContent>
            </ModalDialog>
        </Modal>
    );
}
