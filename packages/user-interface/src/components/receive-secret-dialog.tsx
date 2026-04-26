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
import { usePlatform } from '../context/platform-context';

export interface IReceiveSecretDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the receive secret flow.
//
type ReceiveStep = "waiting" | "review" | "success" | "error";

//
// Payload shape received from the sender (matches ISecretSharePayload).
//
interface IReceivedSecretPayload {
    // Discriminator.
    type: "secret";

    // The name of the secret on the sender's device.
    name: string;

    // Category of secret.
    secretType: string;

    // JSON value string.
    value: string;
}

//
// Dialog for receiving a secret from another device over the LAN.
//
export function ReceiveSecretDialog({ open, onClose }: IReceiveSecretDialogProps) {
    const platform = usePlatform();
    const [step, setStep] = useState<ReceiveStep>("waiting");
    const [pairingCode, setPairingCode] = useState("");
    const [payload, setPayload] = useState<IReceivedSecretPayload | null>(null);
    const [saveName, setSaveName] = useState("");
    const [errorMessage, setErrorMessage] = useState("");

    // Start receiving when dialog opens
    useEffect(() => {
        if (!open) {
            return;
        }

        setStep("waiting");
        setPairingCode("");
        setPayload(null);
        setSaveName("");
        setErrorMessage("");

        let cancelled = false;

        async function startReceiving(): Promise<void> {
            const info = await platform.startShareReceive();
            if (cancelled) {
                return;
            }
            setPairingCode(info.code);

            const received = await platform.waitShareReceive();
            if (cancelled) {
                return;
            }

            if (!received) {
                setErrorMessage("No sender connected within 60 seconds.");
                setStep("error");
                return;
            }

            const receivedPayload = received as IReceivedSecretPayload;
            setPayload(receivedPayload);

            setSaveName(receivedPayload.name);
            setStep("review");
        }

        startReceiving().catch(error => {
            if (!cancelled) {
                setErrorMessage(String(error));
                setStep("error");
            }
        });

        return () => {
            cancelled = true;
            platform.cancelShareReceive().catch(() => {});
        };
    }, [open, platform]);

    //
    // Saves the received secret payload locally.
    //
    const handleSave = useCallback(async () => {
        if (!payload) {
            return;
        }

        await platform.importSharePayload({
            ...payload,
            saveName: `shared:${saveName}`,
        }, {});
        setStep("success");
    }, [payload, saveName, platform]);

    //
    // Cancels the receiver and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "waiting") {
            await platform.cancelShareReceive();
        }
        onClose();
    }, [step, platform, onClose]);

    return (
        <Modal open={open} onClose={handleCancel}>
            <ModalDialog sx={{ minWidth: 420, maxWidth: 520 }}>
                <DialogTitle>Receive Secret</DialogTitle>
                <DialogContent>
                    <Typography level="body-sm" sx={{ mb: 2 }} color="neutral">
                        Click Share on a secret on another device to send it here.
                    </Typography>

                    {step === "waiting" && (
                        <Box sx={{ textAlign: "center", py: 3 }}>
                            {pairingCode ? (
                                <>
                                    <Typography level="body-lg" sx={{ mb: 1 }}>Pairing Code</Typography>
                                    <Typography level="h2" sx={{ fontFamily: "monospace", letterSpacing: "0.3em", mb: 2 }}>
                                        {pairingCode}
                                    </Typography>
                                    <Box sx={{ display: "flex", alignItems: "center", gap: 2, justifyContent: "center" }}>
                                        <CircularProgress size="sm" />
                                        <Typography level="body-sm">Waiting for sender...</Typography>
                                    </Box>
                                </>
                            ) : (
                                <Box sx={{ display: "flex", alignItems: "center", gap: 2, justifyContent: "center" }}>
                                    <CircularProgress size="sm" />
                                    <Typography>Starting receiver...</Typography>
                                </Box>
                            )}
                        </Box>
                    )}

                    {step === "review" && payload && (
                        <>
                            <Typography level="body-md" sx={{ mb: 2 }}>
                                <strong>Type:</strong> {payload.secretType}
                            </Typography>

                            <FormControl>
                                <FormLabel>Save as (name)</FormLabel>
                                <Input
                                    value={saveName}
                                    onChange={event => setSaveName(event.target.value)}
                                    placeholder="my-secret"
                                />
                            </FormControl>
                        </>
                    )}

                    {step === "success" && (
                        <Alert color="success">
                            Secret imported successfully!
                        </Alert>
                    )}

                    {step === "error" && (
                        <Alert color="danger">
                            {errorMessage}
                        </Alert>
                    )}
                </DialogContent>
                <DialogActions>
                    {step === "waiting" && (
                        <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "review" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                disabled={!saveName.trim()}
                                onClick={() => { handleSave().catch(err => console.error("Import error:", err)); }}
                            >
                                Save
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
