import { log } from "utils";
import React, { useState, useEffect, useCallback } from 'react';
import { ResponsiveDialog } from './responsive-dialog';
import Key from '@mui/icons-material/Key';
import WifiTethering from '@mui/icons-material/WifiTethering';
import { DialogIconBadge } from './dialog-icon-badge';
import { DetailRows, PairingCodeTiles, PulsingSearch, StepDots, StepTransition, SuccessCheck } from './lan-share-parts';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import Typography from '@mui/material/Typography';
import Alert from '@mui/material/Alert';
import Box from '@mui/material/Box';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { lanShareErrorMessage, noReceiverMessage } from '../lib/lan-share-error-message';
import { useLanShareTasks } from "../lib/use-lan-share-tasks";

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

    // The LAN sharing flow, run as tasks on the shared task queue.
    const lanShare = useLanShareTasks();
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

        try {
            // Get the secret value and build the payload
            const value = await platform.getSecretValue(entry.name);
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

            const found = await lanShare.waitForReceiver(payload, code);
            if (!found.endpoint) {
                setErrorMessage(noReceiverMessage(found.sawMismatchedReceiver));
                setStep("error");
                return;
            }

            const success = await lanShare.sendToReceiver(found.endpoint);
            if (success) {
                setStep("success");
            }
            else {
                setErrorMessage("Pairing code rejected by receiver.");
                setStep("error");
            }
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog spinning on the pairing code.
            log.exception("Share error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
    }, [entry, platform]);

    //
    // Cancels the sender and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "showing-code") {
            await lanShare.cancelShareSend();
        }
        onClose();
    }, [step, platform, onClose]);

    //
    // The primary action for the current step: send while confirming, or close once finished.
    //
    async function handleDialogConfirm(): Promise<void> {
        if (step === "confirm") {
            await handleStartSend();
        }
        else if (step === "success" || step === "error") {
            onClose();
        }
    }

    // Enter does nothing while searching or showing the pairing code (only Cancel is available then).
    const dialogConfirmDisabled = step === "searching" || step === "showing-code";

    // The step dots count the error step as the last step, the place the success step takes.
    let stepIndex = 3;
    if (step !== "error") {
        stepIndex = ["confirm", "searching", "showing-code", "success"].indexOf(step);
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={handleCancel}
            minWidth={420}
            maxWidth={520}
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
            <DialogTitle><DialogIconBadge icon={<Key />} danger={false} />Share Secret</DialogTitle>
            <DialogContent>
                <StepDots index={stepIndex} count={4} />
                <Box
                    sx={{
                        display: "flex",
                        flexDirection: "column",
                        gap: "var(--space-4)",
                    }}
                    >
                    <Alert severity="warning">
                        Both devices must be on the same local network (wired or Wi-Fi). This does not work over the internet.
                    </Alert>

                    <Typography
                        variant="body2"
                        sx={{
                            color: "var(--color-text-muted)",
                        }}
                        >
                        Click Receive secret on another device to receive this secret.
                    </Typography>

                    <StepTransition step={step} forward={true}>
                        {step === "confirm" && (
                            <DetailRows
                                details={[
                                    {
                                        label: "Name:",
                                        value: entry.name,
                                        dataId: undefined,
                                    },
                                    {
                                        label: "Type:",
                                        value: entry.type,
                                        dataId: undefined,
                                    },
                                ]}
                                />
                        )}

                        {step === "searching" && (
                            <PulsingSearch icon={<WifiTethering />} message="Searching for receiver on the local network..." />
                        )}

                        {step === "showing-code" && (
                            <Box
                                sx={{
                                    display: "flex",
                                    flexDirection: "column",
                                    alignItems: "center",
                                    gap: "var(--space-3)",
                                    padding: "var(--space-4) 0",
                                    textAlign: "center",
                                }}
                                >
                                <Typography
                                    sx={{
                                        color: "var(--color-text-muted)",
                                        fontSize: "var(--text-sm)",
                                        fontWeight: "var(--weight-bold)",
                                    }}
                                    >
                                    Pairing Code
                                </Typography>
                                <PairingCodeTiles code={pairingCode} dataId="share-pairing-code" />
                                <Typography>Tell the receiver to enter this code.</Typography>
                            </Box>
                        )}

                        {step === "success" && (
                            <SuccessCheck dataId={undefined}>
                                Secret sent successfully!
                            </SuccessCheck>
                        )}

                        {step === "error" && (
                            <Alert data-id="share-error-message" severity="error">
                                {errorMessage}
                            </Alert>
                        )}
                    </StepTransition>
                </Box>
            </DialogContent>
            <DialogActions>
                {step === "confirm" && (
                    <>
                        <Button data-id="share-secret-cancel-button" variant="outlined" onClick={handleCancel}>Cancel</Button>
                        <Button data-id="share-secret-send-button" variant="contained" onClick={() => { handleStartSend(); }}>
                            Send
                        </Button>
                    </>
                )}

                {step === "searching" && (
                    <Button data-id="share-secret-cancel-button" variant="outlined" onClick={handleCancel}>Cancel</Button>
                )}

                {step === "showing-code" && (
                    <Button data-id="share-secret-cancel-button" variant="outlined" onClick={handleCancel}>Cancel</Button>
                )}

                {(step === "success" || step === "error") && (
                    <Button data-id="share-secret-close-button" variant="contained" onClick={onClose}>Close</Button>
                )}
            </DialogActions>
        </ResponsiveDialog>
    );
}
