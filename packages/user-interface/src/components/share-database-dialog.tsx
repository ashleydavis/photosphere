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
import Checkbox from '@mui/joy/Checkbox';
import Box from '@mui/joy/Box';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';

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
type ShareStep = "review" | "searching" | "enter-code" | "success" | "error";

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
    const [endpoint, setEndpoint] = useState<unknown>(null);
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
            setEndpoint(null);
            setErrorMessage("");
        }
    }, [open, entry]);

    //
    // Builds the share payload from form state and starts searching for a receiver.
    //
    const handleStartSend = useCallback(async () => {
        setStep("searching");

        // Build payload from the entry — the main process resolves secrets server-side
        // so we pass the database entry fields plus flags for which secrets to include.
        const payload = {
            type: "database" as const,
            name: form.name,
            description: form.description,
            path: form.path,
            origin: entry.origin,
            includeS3: form.includeS3,
            includeEncryption: form.includeEncryption,
            includeGeocoding: form.includeGeocoding,
            // The main process will resolve the actual secrets from the vault
            s3Key: form.includeS3 ? entry.s3Key : undefined,
            encryptionKey: form.includeEncryption ? entry.encryptionKey : undefined,
            geocodingKey: form.includeGeocoding ? entry.geocodingKey : undefined,
        };

        const foundEndpoint = await platform.waitForReceiver(payload);
        if (!foundEndpoint) {
            setErrorMessage("No receiver found within 60 seconds.");
            setStep("error");
            return;
        }

        setEndpoint(foundEndpoint);
        setStep("enter-code");
    }, [form, entry, platform]);

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
            <ModalDialog sx={{ minWidth: 480, maxWidth: 600 }}>
                <DialogTitle>Share Database</DialogTitle>
                <DialogContent>
                    <Alert color="warning" sx={{ mb: 2 }}>
                        Credentials will be shared over your local network. Only use this on a trusted network.
                    </Alert>

                    <Typography level="body-sm" sx={{ mb: 2 }} color="neutral">
                        Click Receive Database on another device to receive this database.
                    </Typography>

                    {step === "review" && (
                        <>
                            <FormControl sx={{ mb: 1 }}>
                                <FormLabel>Name</FormLabel>
                                <Input
                                    value={form.name}
                                    onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                                />
                            </FormControl>

                            <FormControl sx={{ mb: 1 }}>
                                <FormLabel>Description</FormLabel>
                                <Input
                                    value={form.description}
                                    onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                                />
                            </FormControl>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Path</FormLabel>
                                <Input
                                    value={form.path}
                                    onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                />
                            </FormControl>

                            {entry.s3Key && (
                                <Checkbox
                                    label="Include S3 credentials"
                                    checked={form.includeS3}
                                    onChange={event => setForm(prev => ({ ...prev, includeS3: event.target.checked }))}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {entry.encryptionKey && (
                                <Checkbox
                                    label="Include encryption key"
                                    checked={form.includeEncryption}
                                    onChange={event => setForm(prev => ({ ...prev, includeEncryption: event.target.checked }))}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {entry.geocodingKey && (
                                <Checkbox
                                    label="Include geocoding key"
                                    checked={form.includeGeocoding}
                                    onChange={event => setForm(prev => ({ ...prev, includeGeocoding: event.target.checked }))}
                                    sx={{ mb: 1 }}
                                />
                            )}
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
                            Database sent successfully!
                        </Alert>
                    )}

                    {step === "error" && (
                        <Alert color="danger">
                            {errorMessage}
                        </Alert>
                    )}
                </DialogContent>
                <DialogActions>
                    {step === "review" && (
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
