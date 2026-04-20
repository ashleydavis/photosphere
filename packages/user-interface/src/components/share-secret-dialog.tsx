import React, { useState, useEffect, useCallback } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Input from '@mui/joy/Input';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Typography from '@mui/joy/Typography';
import Alert from '@mui/joy/Alert';
import CircularProgress from '@mui/joy/CircularProgress';
import Box from '@mui/joy/Box';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';

export interface IShareSecretDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The secret entry to share.
    entry: ISharedSecretEntry;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the share secret flow.
//
type ShareStep = "confirm" | "searching" | "enter-code" | "success" | "error";

//
// Dialog for sharing a secret to another device over the LAN.
//
export function ShareSecretDialog({ open, entry, onClose }: IShareSecretDialogProps) {
    const platform = usePlatform();
    const [step, setStep] = useState<ShareStep>("confirm");
    const [pairingCode, setPairingCode] = useState("");
    const [endpoint, setEndpoint] = useState<unknown>(null);
    const [errorMessage, setErrorMessage] = useState("");

    // Reset state when dialog opens
    useEffect(() => {
        if (open) {
            setStep("confirm");
            setPairingCode("");
            setEndpoint(null);
            setErrorMessage("");
        }
    }, [open]);

    //
    // Builds the secret payload and starts searching for a receiver.
    //
    const handleStartSend = useCallback(async () => {
        setStep("searching");

        // Get the secret value and build the payload
        const value = await platform.getSecretValue(entry.id);
        if (!value) {
            setErrorMessage("Could not read secret value.");
            setStep("error");
            return;
        }

        const payload = {
            type: "secret" as const,
            secretType: entry.type,
            value,
        };

        const foundEndpoint = await platform.waitForReceiver(payload);
        if (!foundEndpoint) {
            setErrorMessage("No receiver found within 60 seconds.");
            setStep("error");
            return;
        }

        setEndpoint(foundEndpoint);
        setStep("enter-code");
    }, [entry, platform]);

    //
    // Sends the payload to the receiver with the entered pairing code.
    //
    const handleSend = useCallback(async () => {
        if (!endpoint) {
            return;
        }

        const success = await platform.sendToReceiver(endpoint, pairingCode);
        if (success) {
            setStep("success");
        }
        else {
            setErrorMessage("Pairing code rejected by receiver.");
            setStep("error");
        }
    }, [endpoint, pairingCode, platform]);

    //
    // Cancels the sender and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "searching") {
            await platform.cancelShareSend();
        }
        onClose();
    }, [step, platform, onClose]);

    return (
        <Modal open={open} onClose={handleCancel}>
            <ModalDialog sx={{ minWidth: 420, maxWidth: 520 }}>
                <DialogTitle>Share Secret</DialogTitle>
                <DialogContent>
                    <Alert color="warning" sx={{ mb: 2 }}>
                        Credentials will be shared over your local network. Only use this on a trusted network.
                    </Alert>

                    <Typography level="body-sm" sx={{ mb: 2 }} color="neutral">
                        Click Receive Secret on another device to receive this secret.
                    </Typography>

                    {step === "confirm" && (
                        <>
                            <Typography level="body-md" sx={{ mb: 1 }}>
                                <strong>Name:</strong> {entry.name}
                            </Typography>
                            <Typography level="body-md">
                                <strong>Type:</strong> {entry.type}
                            </Typography>
                        </>
                    )}

                    {step === "searching" && (
                        <Box sx={{ display: "flex", alignItems: "center", gap: 2, py: 3, justifyContent: "center" }}>
                            <CircularProgress size="sm" />
                            <Typography>Searching for receiver on the LAN...</Typography>
                        </Box>
                    )}

                    {step === "enter-code" && (
                        <FormControl>
                            <FormLabel>Enter the 4-digit pairing code shown on the receiver</FormLabel>
                            <Input
                                value={pairingCode}
                                onChange={event => setPairingCode(event.target.value)}
                                slotProps={{ input: { maxLength: 4 } }}
                                placeholder="0000"
                            />
                        </FormControl>
                    )}

                    {step === "success" && (
                        <Alert color="success">
                            Secret sent successfully!
                        </Alert>
                    )}

                    {step === "error" && (
                        <Alert color="danger">
                            {errorMessage}
                        </Alert>
                    )}
                </DialogContent>
                <DialogActions>
                    {step === "confirm" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button onClick={() => { handleStartSend().catch(err => console.error("Share error:", err)); }}>
                                Send
                            </Button>
                        </>
                    )}

                    {step === "searching" && (
                        <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "enter-code" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                disabled={!/^\d{4}$/.test(pairingCode)}
                                onClick={() => { handleSend().catch(err => console.error("Send error:", err)); }}
                            >
                                Send
                            </Button>
                        </>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
