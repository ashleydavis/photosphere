import { log } from "utils";
import React, { useState, useEffect, useCallback } from 'react';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import FormControlLabel from '@mui/material/FormControlLabel';
import Typography from '@mui/material/Typography';
import Alert from '@mui/material/Alert';
import CircularProgress from '@mui/material/CircularProgress';
import Checkbox from '@mui/material/Checkbox';
import Box from '@mui/material/Box';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';
import type { IDatabaseSharePayload, IShareS3Credentials, IShareEncryptionKey, IShareGeocodingKey } from '../lib/lan-share';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { lanShareErrorMessage, noReceiverMessage } from '../lib/lan-share-error-message';
import { useLanShareTasks } from "../lib/use-lan-share-tasks";
import { ResponsiveDialog } from './responsive-dialog';

export interface IShareDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The database entry to share.
    entry: IDatabaseEntry;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the share database flow.
//
type ShareStep = "review" | "searching" | "showing-code" | "success" | "error";

//
// Form state for the share database dialog.
//
interface IShareFormState {
    // Editable database name.
    name: string;

    // Editable description.
    description: string;

    // Editable path.
    path: string;

    // Whether to include S3 credentials.
    includeS3: boolean;

    // Whether to include encryption key.
    includeEncryption: boolean;

    // Whether to include geocoding key.
    includeGeocoding: boolean;
}

//
// Dialog for sharing a database config with secrets to another device over the LAN.
//
export function ShareDatabaseDialog({ open, entry, onClose }: IShareDatabaseDialogProps) {
    const platform = usePlatform();

    // The LAN sharing flow, run as tasks on the shared task queue.
    const lanShare = useLanShareTasks();
    const [step, setStep] = useState<ShareStep>("review");
    const [form, setForm] = useState<IShareFormState>({
        name: "",
        description: "",
        path: "",
        includeS3: true,
        includeEncryption: true,
        includeGeocoding: true,
    });
    const [pairingCode, setPairingCode] = useState("");
    const [errorMessage, setErrorMessage] = useState("");

    // Reset state when dialog opens
    useEffect(() => {
        if (open) {
            setStep("review");
            setForm({
                name: entry.name,
                description: entry.description || "",
                path: entry.path,
                includeS3: !!entry.s3Key,
                includeEncryption: !!entry.encryptionKey,
                includeGeocoding: !!entry.geocodingKey,
            });
            setPairingCode("");
            setErrorMessage("");
        }
    }, [open, entry]);

    //
    // Generates a pairing code, shows it to the user, then waits for a receiver and auto-sends.
    //
    const handleStartSend = useCallback(async () => {
        const code = String(Math.floor(1000 + Math.random() * 9000));
        setPairingCode(code);
        setStep("showing-code");

        try {
            let s3Credentials: IShareS3Credentials | undefined;
            if (form.includeS3 && entry.s3Key) {
                const valueJson = await platform.getSecretValue(entry.s3Key);
                if (valueJson) {
                    const parsed = JSON.parse(valueJson);
                    s3Credentials = {
                        name: entry.s3Key,
                        region: parsed.region,
                        accessKeyId: parsed.accessKeyId,
                        secretAccessKey: parsed.secretAccessKey,
                        endpoint: parsed.endpoint,
                    };
                }
            }

            let encryptionKey: IShareEncryptionKey | undefined;
            if (form.includeEncryption && entry.encryptionKey) {
                const valueJson = await platform.getSecretValue(entry.encryptionKey);
                if (valueJson) {
                    encryptionKey = {
                        name: entry.encryptionKey,
                        privateKeyPem: valueJson,
                        publicKeyPem: "",
                    };
                }
            }

            let geocodingKey: IShareGeocodingKey | undefined;
            if (form.includeGeocoding && entry.geocodingKey) {
                const valueJson = await platform.getSecretValue(entry.geocodingKey);
                if (valueJson) {
                    geocodingKey = {
                        name: entry.geocodingKey,
                        apiKey: valueJson,
                    };
                }
            }

            const payload: IDatabaseSharePayload = {
                type: "database",
                name: form.name.trim(),
                description: form.description,
                path: form.path.trim(),
                origin: entry.origin,
                s3Credentials,
                encryptionKey,
                geocodingKey,
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
    }, [form, entry, platform]);

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
    // The primary action for the current step: send while reviewing, or close once finished.
    //
    async function handleDialogConfirm(): Promise<void> {
        if (step === "review") {
            await handleStartSend();
        }
        else if (step === "success" || step === "error") {
            onClose();
        }
    }

    // Enter does nothing while searching or showing the pairing code (only Cancel is available then).
    const dialogConfirmDisabled = step === "searching" || step === "showing-code";

    return (
        <ResponsiveDialog
            open={open}
            onClose={handleCancel}
            minWidth={480}
            maxWidth={600}
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
            <DialogTitle>Share Database</DialogTitle>
            <DialogContent>
                <Alert severity="warning" sx={{ mb: 2 }}>
                    Both devices must be on the same local network (wired or Wi-Fi). This does not work over the internet.
                </Alert>

                <Typography variant="body2" sx={{ mb: 2 }} color="text.secondary">
                    Click Receive Database on another device to receive this database.
                </Typography>

                {step === "review" && (
                    <>
                        <FormControl fullWidth sx={{ mb: 1 }}>
                            <FormLabel>Name</FormLabel>
                            <OutlinedInput
                                size="small"
                                value={form.name}
                                onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl fullWidth sx={{ mb: 1 }}>
                            <FormLabel>Description</FormLabel>
                            <OutlinedInput
                                size="small"
                                value={form.description}
                                onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl fullWidth sx={{ mb: 2 }}>
                            <FormLabel>Path</FormLabel>
                            <OutlinedInput
                                size="small"
                                value={form.path}
                                onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                            />
                        </FormControl>

                        {entry.s3Key && (
                            <FormControlLabel
                                label="Include S3 credentials"
                                control={
                                    <Checkbox
                                        checked={form.includeS3}
                                        onChange={event => setForm(prev => ({ ...prev, includeS3: event.target.checked }))}
                                    />
                                }
                                sx={{ display: "flex", mb: 1 }}
                            />
                        )}

                        {entry.encryptionKey && (
                            <FormControlLabel
                                label="Include encryption key"
                                control={
                                    <Checkbox
                                        checked={form.includeEncryption}
                                        onChange={event => setForm(prev => ({ ...prev, includeEncryption: event.target.checked }))}
                                    />
                                }
                                sx={{ display: "flex", mb: 1 }}
                            />
                        )}

                        {entry.geocodingKey && (
                            <FormControlLabel
                                label="Include geocoding key"
                                control={
                                    <Checkbox
                                        checked={form.includeGeocoding}
                                        onChange={event => setForm(prev => ({ ...prev, includeGeocoding: event.target.checked }))}
                                    />
                                }
                                sx={{ display: "flex", mb: 1 }}
                            />
                        )}
                    </>
                )}

                {step === "searching" && (
                    <Box sx={{ display: "flex", alignItems: "center", gap: 2, py: 3, justifyContent: "center" }}>
                        <CircularProgress size={24} />
                        <Typography>Searching for receiver on the local network...</Typography>
                    </Box>
                )}

                {step === "showing-code" && (
                    <Box sx={{ textAlign: "center", py: 3 }}>
                        <Typography variant="body1" sx={{ mb: 1 }}>Pairing Code</Typography>
                        <Typography data-id="share-pairing-code" variant="h4" sx={{ fontFamily: "monospace", letterSpacing: "0.3em", mb: 2 }}>
                            {pairingCode}
                        </Typography>
                        <Typography variant="body2">Tell the receiver to enter this code.</Typography>
                    </Box>
                )}

                {step === "success" && (
                    <Alert severity="success">
                        Database sent successfully!
                    </Alert>
                )}

                {step === "error" && (
                    <Alert severity="error">
                        {errorMessage}
                    </Alert>
                )}
            </DialogContent>
            <DialogActions>
                {step === "review" && (
                    <>
                        <Button data-id="share-database-cancel-button" variant="text" onClick={handleCancel}>Cancel</Button>
                        <Button data-id="share-database-send-button" variant="contained" onClick={() => { handleStartSend(); }}>
                            Send
                        </Button>
                    </>
                )}

                {step === "searching" && (
                    <Button data-id="share-database-cancel-button" variant="text" onClick={handleCancel}>Cancel</Button>
                )}

                {step === "showing-code" && (
                    <Button data-id="share-database-cancel-button" variant="text" onClick={handleCancel}>Cancel</Button>
                )}

                {(step === "success" || step === "error") && (
                    <Button data-id="share-database-close-button" variant="contained" onClick={onClose}>Close</Button>
                )}
            </DialogActions>
        </ResponsiveDialog>
    );
}
