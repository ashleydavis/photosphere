import { log } from "utils";
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
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import type { IConflictResolution } from 'lan-share';
import { usePlatform } from '../context/platform-context';

export interface IReceiveDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the receive database flow.
//
type ReceiveStep = "enter-code" | "waiting" | "review" | "conflict" | "success" | "error";

//
// A single secret included in a received payload (name + label only).
//
interface IReceivedSecret {
    // Vault key name from the sender.
    name: string;

    // Human-readable label.
    label: string;
}

//
// Payload shape received from the sender (matches IDatabaseSharePayload).
//
interface IReceivedDatabasePayload {
    // Discriminator.
    type: "database";

    // Editable database name.
    name: string;

    // Editable description.
    description: string;

    // Editable path.
    path: string;

    // Optional origin.
    origin?: string;

    // Resolved S3 credentials, if included.
    s3Credentials?: IReceivedSecret;

    // Resolved encryption key, if included.
    encryptionKey?: IReceivedSecret;

    // Resolved geocoding key, if included.
    geocodingKey?: IReceivedSecret;
}

//
// A conflicting secret that needs the user to choose a resolution.
//
interface ISecretConflict {
    // Vault key name that already exists on this device.
    secretName: string;

    // Secret type (e.g. "s3-credentials", "encryption-key").
    secretType: string;

    // Current resolution chosen by the user.
    resolution: IConflictResolution;
}

//
// Dialog for receiving a database config from another device over the LAN.
//
export function ReceiveDatabaseDialog({ open, onClose }: IReceiveDatabaseDialogProps) {
    const platform = usePlatform();
    const [step, setStep] = useState<ReceiveStep>("enter-code");
    const [enteredCode, setEnteredCode] = useState("");
    const [payload, setPayload] = useState<IReceivedDatabasePayload | null>(null);
    const [editedName, setEditedName] = useState("");
    const [editedDescription, setEditedDescription] = useState("");
    const [editedPath, setEditedPath] = useState("");
    const [importS3, setImportS3] = useState(true);
    const [importEncryption, setImportEncryption] = useState(true);
    const [importGeocoding, setImportGeocoding] = useState(true);
    const [conflicts, setConflicts] = useState<ISecretConflict[]>([]);
    const [errorMessage, setErrorMessage] = useState("");

    // Reset state when dialog opens
    useEffect(() => {
        if (!open) {
            return;
        }
        setStep("enter-code");
        setEnteredCode("");
        setPayload(null);
        setErrorMessage("");
    }, [open]);

    //
    // Starts the receiver with the entered code, waits for the sender payload, then moves to review.
    //
    const handleStartReceiving = useCallback(async () => {
        await platform.startShareReceive(enteredCode);
        setStep("waiting");

        const received = await platform.waitShareReceive();

        if (!received) {
            setErrorMessage("No sender connected within 60 seconds.");
            setStep("error");
            return;
        }

        const receivedPayload = received as IReceivedDatabasePayload;
        setPayload(receivedPayload);
        setEditedName(receivedPayload.name);
        setEditedDescription(receivedPayload.description || "");
        setEditedPath(receivedPayload.path);
        setImportS3(!!receivedPayload.s3Credentials);
        setImportEncryption(!!receivedPayload.encryptionKey);
        setImportGeocoding(!!receivedPayload.geocodingKey);
        setStep("review");
    }, [enteredCode, platform]);

    //
    // Checks whether any of the secrets to be imported already exist in the
    // vault. Returns the list of conflicts found.
    //
    async function detectConflicts(currentPayload: IReceivedDatabasePayload): Promise<ISecretConflict[]> {
        const secretsToCheck: Array<{ secret: IReceivedSecret; secretType: string; shouldImport: boolean }> = [
            { secret: currentPayload.s3Credentials!, secretType: "s3-credentials", shouldImport: importS3 && !!currentPayload.s3Credentials },
            { secret: currentPayload.encryptionKey!, secretType: "encryption-key", shouldImport: importEncryption && !!currentPayload.encryptionKey },
            { secret: currentPayload.geocodingKey!, secretType: "api-key", shouldImport: importGeocoding && !!currentPayload.geocodingKey },
        ];

        const found: ISecretConflict[] = [];
        for (const entry of secretsToCheck) {
            if (!entry.shouldImport) {
                continue;
            }
            const existing = await platform.getSecretValue(entry.secret.name);
            if (existing !== undefined) {
                found.push({
                    secretName: entry.secret.name,
                    secretType: entry.secretType,
                    resolution: { action: "reuse" },
                });
            }
        }
        return found;
    }

    //
    // Attempts to save the received database, checking for conflicts first.
    //
    const handleSave = useCallback(async () => {
        if (!payload) {
            return;
        }

        const found = await detectConflicts(payload);
        if (found.length > 0) {
            setConflicts(found);
            setStep("conflict");
            return;
        }

        await doImport({});
    }, [payload, importS3, importEncryption, importGeocoding]);

    //
    // Proceeds with the import after conflicts have been resolved.
    //
    const handleConflictsResolved = useCallback(async () => {
        const resolutions: Record<string, IConflictResolution> = {};
        for (const conflict of conflicts) {
            resolutions[conflict.secretName] = conflict.resolution;
        }
        await doImport(resolutions);
    }, [conflicts]);

    //
    // Performs the actual import with the given conflict resolutions map.
    //
    async function doImport(conflictResolutions: Record<string, IConflictResolution>): Promise<void> {
        if (!payload) {
            return;
        }

        const importPayload = {
            ...payload,
            name: editedName,
            description: editedDescription,
            path: editedPath,
            s3Credentials: importS3 ? payload.s3Credentials : undefined,
            encryptionKey: importEncryption ? payload.encryptionKey : undefined,
            geocodingKey: importGeocoding ? payload.geocodingKey : undefined,
        };

        await platform.importSharePayload(importPayload, conflictResolutions);
        setStep("success");
    }

    //
    // Updates the resolution action for a specific conflict.
    //
    function setConflictAction(secretName: string, action: IConflictResolution["action"]): void {
        setConflicts(prev => prev.map(conflict => {
            if (conflict.secretName !== secretName) {
                return conflict;
            }
            if (action === "rename") {
                return { ...conflict, resolution: { action, newName: secretName } };
            }
            return { ...conflict, resolution: { action } };
        }));
    }

    //
    // Updates the rename target for a specific conflict.
    //
    function setConflictNewName(secretName: string, newName: string): void {
        setConflicts(prev => prev.map(conflict => {
            if (conflict.secretName !== secretName) {
                return conflict;
            }
            return { ...conflict, resolution: { action: "rename", newName } };
        }));
    }

    //
    // Cancels the receiver and closes the dialog.
    //
    const handleCancel = useCallback(async () => {
        if (step === "waiting") {
            await platform.cancelShareReceive();
        }
        onClose();
    }, [step, platform, onClose]);

    const conflictResolutionInvalid = conflicts.some(
        conflict => conflict.resolution.action === "rename" && !conflict.resolution.newName?.trim()
    );

    return (
        <Modal open={open} onClose={handleCancel}>
            <ModalDialog sx={{ minWidth: 480, maxWidth: 600 }}>
                <DialogTitle>Receive Database</DialogTitle>
                <DialogContent>
                    <Typography level="body-sm" sx={{ mb: 2 }} color="neutral">
                        Click Share on a database on another device to send it here.
                    </Typography>

                    {step === "enter-code" && (
                        <FormControl>
                            <FormLabel>Enter the 4-digit pairing code shown on the sender</FormLabel>
                            <Input
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
                            <FormControl sx={{ mb: 1 }}>
                                <FormLabel>Name</FormLabel>
                                <Input
                                    value={editedName}
                                    onChange={event => setEditedName(event.target.value)}
                                />
                            </FormControl>

                            <FormControl sx={{ mb: 1 }}>
                                <FormLabel>Description</FormLabel>
                                <Input
                                    value={editedDescription}
                                    onChange={event => setEditedDescription(event.target.value)}
                                />
                            </FormControl>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Path</FormLabel>
                                <Input
                                    value={editedPath}
                                    onChange={event => setEditedPath(event.target.value)}
                                />
                            </FormControl>

                            {payload.s3Credentials && (
                                <Checkbox
                                    label={`Import S3 credentials (${payload.s3Credentials.label})`}
                                    checked={importS3}
                                    onChange={event => setImportS3(event.target.checked)}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {payload.encryptionKey && (
                                <Checkbox
                                    label={`Import encryption key (${payload.encryptionKey.label})`}
                                    checked={importEncryption}
                                    onChange={event => setImportEncryption(event.target.checked)}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {payload.geocodingKey && (
                                <Checkbox
                                    label={`Import geocoding key (${payload.geocodingKey.label})`}
                                    checked={importGeocoding}
                                    onChange={event => setImportGeocoding(event.target.checked)}
                                    sx={{ mb: 1 }}
                                />
                            )}
                        </>
                    )}

                    {step === "conflict" && (
                        <>
                            <Alert color="warning" sx={{ mb: 2 }}>
                                Some secrets already exist in your vault. Choose what to do with each one.
                            </Alert>

                            {conflicts.map(conflict => (
                                <Box key={conflict.secretName} sx={{ mb: 2, p: 1.5, border: "1px solid", borderColor: "neutral.300", borderRadius: "sm" }}>
                                    <Typography level="body-sm" fontWeight="bold" sx={{ mb: 0.5 }}>
                                        {conflict.secretName}
                                        <Typography component="span" level="body-xs" color="neutral" sx={{ ml: 1 }}>
                                            ({conflict.secretType})
                                        </Typography>
                                    </Typography>

                                    <Select
                                        value={conflict.resolution.action}
                                        onChange={(_event, value) => setConflictAction(conflict.secretName, value as IConflictResolution["action"])}
                                        sx={{ mb: 1 }}
                                    >
                                        <Option value="reuse">Reuse existing — skip importing this secret</Option>
                                        <Option value="replace">Replace existing — may break other databases using this secret</Option>
                                        <Option value="rename">Save with a new name</Option>
                                    </Select>

                                    {conflict.resolution.action === "rename" && (
                                        <Input
                                            placeholder="New secret name"
                                            value={conflict.resolution.newName || ""}
                                            onChange={event => setConflictNewName(conflict.secretName, event.target.value)}
                                        />
                                    )}
                                </Box>
                            ))}
                        </>
                    )}

                    {step === "success" && (
                        <Alert color="success">
                            Database imported successfully!
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
                                disabled={!/^\d{4}$/.test(enteredCode)}
                                onClick={() => { handleStartReceiving().catch(err => log.exception("Receive error:", err as Error)); }}
                            >
                                Start
                            </Button>
                        </>
                    )}

                    {step === "waiting" && (
                        <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "review" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                disabled={!editedName || !editedPath}
                                onClick={() => { handleSave().catch(err => log.exception("Import error:", err as Error)); }}
                            >
                                Save
                            </Button>
                        </>
                    )}

                    {step === "conflict" && (
                        <>
                            <Button variant="plain" onClick={() => setStep("review")}>Back</Button>
                            <Button
                                disabled={conflictResolutionInvalid}
                                onClick={() => { handleConflictsResolved().catch(err => log.exception("Import error:", err as Error)); }}
                            >
                                Continue
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
