import React, { useState, useEffect, useCallback } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
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
type ShareStep = "confirm" | "searching" | "showing-code" | "success" | "error";

//
// Dialog for sharing a secret to another device over the LAN.
//
export function ShareSecretDialog({ open, entry, onClose }: IShareSecretDialogProps) {
    const platform = usePlatform();
    const [step, setStep] = useState<ShareStep>("confirm");
    const [pairingCode, setPairingCode] = useState("");
    const [errorMessage, setErrorMessage] = useState("");

    // Reset state when dialog opens
    useEffect(() => {
        if (open) {
            setStep("confirm");
            setPairingCode("");
            setErrorMessage("");
        }
    }, [open]);

    //
    // Generates a pairing code, shows it to the user, then waits for a receiver and auto-sends.
    //
    const handleStartSend = useCallback(async () => {
        const code = String(Math.floor(1000 + Math.random() * 9000));
        setPairingCode(code);
        setStep("showing-code");

        // Get the secret value and build the payload
        const value = await platform.getSecretValue(entry.id);
        if (!value) {
            setErrorMessage("Could not read secret value.");
            setStep("error");
            return;
        }

        const payload = {
            type: "secret" as const,
            name: entry.name,
            secretType: entry.type,
            value,
        };

        const foundEndpoint = await platform.waitForReceiver(payload, code);
        if (!foundEndpoint) {
            setErrorMessage("No receiver found within 60 seconds.");
            setStep("error");
            return;
        }

        const success = await platform.sendToReceiver(foundEndpoint);
        if (success) {
            setStep("success");
        }
        else {
            setErrorMessage("Pairing code rejected by receiver.");
            setStep("error");
        }
    }, [entry, platform]);

    //
    // Cancels the sender and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "showing-code") {
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
                        Both devices must be on the same local network (wired or Wi-Fi). This does not work over the internet.
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
                            <Typography>Searching for receiver on the local network...</Typography>
                        </Box>
                    )}

                    {step === "showing-code" && (
                        <Box sx={{ textAlign: "center", py: 3 }}>
                            <Typography level="body-lg" sx={{ mb: 1 }}>Pairing Code</Typography>
                            <Typography level="h2" sx={{ fontFamily: "monospace", letterSpacing: "0.3em", mb: 2 }}>
                                {pairingCode}
                            </Typography>
                            <Typography level="body-sm">Tell the receiver to enter this code.</Typography>
                        </Box>
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

                    {step === "showing-code" && (
                        <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
