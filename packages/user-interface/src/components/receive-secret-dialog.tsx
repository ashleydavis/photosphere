import { log } from "utils";
import React, { useState, useEffect, useCallback } from 'react';
import { ResponsiveDialog } from './responsive-dialog';
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
import { useApp } from '../context/app-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { lanShareErrorMessage } from '../lib/lan-share-error-message';

export interface IReceiveSecretDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the receive secret flow.
//
type ReceiveStep = "enter-code" | "waiting" | "review" | "success" | "error";

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
    const { importSharePayload } = useApp();
    const [step, setStep] = useState<ReceiveStep>("enter-code");
    const [enteredCode, setEnteredCode] = useState("");
    const [payload, setPayload] = useState<IReceivedSecretPayload | null>(null);
    const [saveName, setSaveName] = useState("");
    const [errorMessage, setErrorMessage] = useState("");

    // Reset state when dialog opens
    useEffect(() => {
        if (!open) {
            return;
        }
        log.event('Receive secret dialog opened');
        setStep("enter-code");
        setEnteredCode("");
        setPayload(null);
        setSaveName("");
        setErrorMessage("");
    }, [open]);

    //
    // Starts the receiver with the entered code, waits for the sender payload, then moves to review.
    //
    const handleStartReceiving = useCallback(async () => {
        try {
            await platform.startShareReceive(enteredCode);
            setStep("waiting");

            const received = await platform.waitShareReceive();

            if (!received) {
                setErrorMessage("No sender connected within 60 seconds.");
                setStep("error");
                return;
            }

            const receivedPayload = received as IReceivedSecretPayload;
            setPayload(receivedPayload);
            setSaveName(receivedPayload.name);
            setStep("review");
            log.event('Secret review step');
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog spinning on "Waiting for sender...".
            log.exception("Receive error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
    }, [enteredCode, platform]);

    //
    // Saves the received secret payload locally.
    //
    const handleSave = useCallback(async () => {
        if (!payload) {
            return;
        }

        try {
            await importSharePayload({
                ...payload,
                saveName: saveName.trim(),
            }, {});
            setStep("success");
            log.event('Secret saved');
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog stuck on the review step.
            log.exception("Import error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
    }, [payload, saveName, importSharePayload]);

    //
    // Cancels the receiver and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "waiting") {
            await platform.cancelShareReceive();
        }
        onClose();
    }, [step, platform, onClose]);

    //
    // The primary action for the current step: start receiving, save the reviewed
    // secret, or close once finished.
    //
    async function handleDialogConfirm(): Promise<void> {
        if (step === "enter-code") {
            await handleStartReceiving();
        }
        else if (step === "review") {
            await handleSave();
        }
        else if (step === "success" || step === "error") {
            onClose();
        }
    }

    // Enter mirrors the enabled state of each step's primary button.
    const dialogConfirmDisabled =
        (step === "enter-code" && !/^\d{4}$/.test(enteredCode))
        || (step === "review" && !saveName.trim())
        || step === "waiting";

    return (
        <ResponsiveDialog
            open={open}
            onClose={handleCancel}
            minWidth={420}
            maxWidth={520}
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
                <DialogTitle>Receive Secret</DialogTitle>
                <DialogContent>
                    <Typography level="body-sm" sx={{ mb: 2 }} color="neutral">
                        Click Share on a secret on another device to send it here.
                    </Typography>

                    {step === "enter-code" && (
                        <FormControl>
                            <FormLabel>Enter the 4-digit pairing code shown on the sender</FormLabel>
                            <Input
                                data-id="receive-secret-code-input"
                                value={enteredCode}
                                onChange={event => setEnteredCode(event.target.value)}
                                slotProps={{ input: { maxLength: 4 } }}
                                placeholder="0000"
                            />
                        </FormControl>
                    )}

                    {step === "waiting" && (
                        <Box sx={{ display: "flex", alignItems: "center", gap: 2, py: 3, justifyContent: "center" }}>
                            <CircularProgress size="sm" />
                            <Typography>Waiting for sender...</Typography>
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
                    {step === "enter-code" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                data-id="receive-secret-start-button"
                                disabled={!/^\d{4}$/.test(enteredCode)}
                                onClick={() => { handleStartReceiving(); }}
                            >
                                Start
                            </Button>
                        </>
                    )}

                    {step === "waiting" && (
                        <Button data-id="receive-secret-cancel-button" variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "review" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                data-id="receive-secret-save-button"
                                disabled={!saveName.trim()}
                                onClick={() => { handleSave(); }}
                            >
                                Save
                            </Button>
                        </>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button data-id="receive-secret-close-button" onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
        </ResponsiveDialog>
    );
}
