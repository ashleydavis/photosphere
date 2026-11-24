import { log } from "utils";
import React, { useState, useEffect, useCallback } from 'react';
import { ResponsiveDialog } from './responsive-dialog';
import Key from '@mui/icons-material/Key';
import WifiTethering from '@mui/icons-material/WifiTethering';
import { DialogIconBadge } from './dialog-icon-badge';
import { DetailRows, PAIRING_CODE_INPUT_SX, PulsingSearch, StepDots, StepTransition, SuccessCheck } from './lan-share-parts';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import Typography from '@mui/material/Typography';
import Alert from '@mui/material/Alert';
import Box from '@mui/material/Box';
import { usePlatform } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { lanShareErrorMessage, noSenderMessage } from '../lib/lan-share-error-message';
import { useLanShareTasks } from "../lib/use-lan-share-tasks";

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

    // The LAN sharing flow, run as tasks on the shared task queue.
    const lanShare = useLanShareTasks();
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
            await lanShare.startShareReceive(enteredCode);
            setStep("waiting");

            const received = await lanShare.waitShareReceive();

            if (!received.payload) {
                setErrorMessage(noSenderMessage(received.sawMismatchedSender));
                setStep("error");
                return;
            }

            const receivedPayload = received.payload as IReceivedSecretPayload;
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
            await lanShare.cancelShareReceive();
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

    // The step dots count the error step as the last step, the place the success step takes.
    let stepIndex = 3;
    if (step !== "error") {
        stepIndex = ["enter-code", "waiting", "review", "success"].indexOf(step);
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={handleCancel}
            minWidth={420}
            maxWidth={520}
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
                <DialogTitle><DialogIconBadge icon={<Key />} danger={false} />Receive Secret</DialogTitle>
                <DialogContent>
                    <StepDots index={stepIndex} count={4} />
                    <Box
                        sx={{
                            display: "flex",
                            flexDirection: "column",
                            gap: "var(--space-4)",
                        }}
                        >
                        <Typography
                            variant="body2"
                            sx={{
                                color: "var(--color-text-muted)",
                            }}
                            >
                            Click Share on a secret on another device to send it here.
                        </Typography>

                        <StepTransition step={step} forward={true}>
                            {step === "enter-code" && (
                                <FormControl fullWidth>
                                    <FormLabel>Enter the 4-digit pairing code shown on the sender</FormLabel>
                                    <OutlinedInput
                                        size="small"
                                        data-id="receive-secret-code-input"
                                        value={enteredCode}
                                        onChange={event => setEnteredCode(event.target.value)}
                                        slotProps={{
                                            input: {
                                                maxLength: 4,
                                                inputMode: "numeric",
                                                pattern: "[0-9]*",
                                            },
                                        }}
                                        placeholder="0000"
                                        sx={PAIRING_CODE_INPUT_SX}
                                    />
                                </FormControl>
                            )}

                            {step === "waiting" && (
                                <PulsingSearch icon={<WifiTethering />} message="Waiting for sender..." />
                            )}

                            {step === "review" && payload && (
                                <>
                                    <DetailRows
                                        details={[
                                            {
                                                label: "Type:",
                                                value: payload.secretType,
                                                dataId: undefined,
                                            },
                                        ]}
                                        />

                                    <FormControl fullWidth>
                                        <FormLabel>Save as (name)</FormLabel>
                                        <OutlinedInput
                                            size="small"
                                            data-id="receive-secret-name-input"
                                            value={saveName}
                                            onChange={event => setSaveName(event.target.value)}
                                            placeholder="my-secret"
                                        />
                                    </FormControl>
                                </>
                            )}

                            {step === "success" && (
                                <SuccessCheck dataId="receive-secret-success">
                                    Secret imported successfully!
                                </SuccessCheck>
                            )}

                            {step === "error" && (
                                <Alert severity="error">
                                    {errorMessage}
                                </Alert>
                            )}
                        </StepTransition>
                    </Box>
                </DialogContent>
                <DialogActions>
                    {step === "enter-code" && (
                        <>
                            <Button variant="outlined" onClick={handleCancel}>Cancel</Button>
                            <Button
                                data-id="receive-secret-start-button"
                                variant="contained"
                                disabled={!/^\d{4}$/.test(enteredCode)}
                                onClick={() => { handleStartReceiving(); }}
                            >
                                Start
                            </Button>
                        </>
                    )}

                    {step === "waiting" && (
                        <Button data-id="receive-secret-cancel-button" variant="outlined" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "review" && (
                        <>
                            <Button variant="outlined" onClick={handleCancel}>Cancel</Button>
                            <Button
                                data-id="receive-secret-save-button"
                                variant="contained"
                                disabled={!saveName.trim()}
                                onClick={() => { handleSave(); }}
                            >
                                Save
                            </Button>
                        </>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button data-id="receive-secret-close-button" variant="contained" onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
        </ResponsiveDialog>
    );
}
