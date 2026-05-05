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
type ReceiveStep = "enter-code" | "waiting" | "review" | "conflict" | "db-name-conflict" | "success" | "error";

//
// What to do when the imported database name collides with an existing entry.
// "replace" deletes the existing entry then imports; "rename" imports under a new name.
//
type DbNameConflictAction = "replace" | "rename";

//
// A single secret included in a received payload.
//
interface IReceivedSecret {
    // Vault key name from the sender.
    name: string;
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

    // Database-name conflict resolution: which action and (when renaming) what new name.
    const [dbNameConflictAction, setDbNameConflictAction] = useState<DbNameConflictAction>("replace");
    const [dbNameConflictRename, setDbNameConflictRename] = useState("");
    // Inline error shown beneath the rename input when the user types a still-colliding name.
    const [dbNameConflictRenameError, setDbNameConflictRenameError] = useState<string | undefined>(undefined);
    // The existing entry that the new database collides with (used for the Replace path).
    const [existingDbName, setExistingDbName] = useState<string | undefined>(undefined);

    // Reset state when dialog opens
    useEffect(() => {
        if (!open) {
            return;
        }
        log.event('Receive database dialog opened');
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
        log.event('Database review step');
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
    // Attempts to save the received database. First checks for secret conflicts (vault),
    // then for database-name conflicts. Each conflict shows its own step before the actual
    // import runs.
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

        await proceedAfterSecretConflicts({});
    }, [payload, importS3, importEncryption, importGeocoding, editedName]);

    //
    // Called after secret conflicts are resolved (or skipped when none exist).
    // Detects a database-name collision and routes to the db-name-conflict step if needed.
    //
    async function proceedAfterSecretConflicts(secretResolutions: Record<string, IConflictResolution>): Promise<void> {
        const trimmedName = editedName.trim();
        const existing = await platform.findDatabase(trimmedName);
        if (existing) {
            setExistingDbName(existing.name);
            setDbNameConflictAction("replace");
            setDbNameConflictRename(trimmedName);
            setDbNameConflictRenameError(undefined);
            setPendingSecretResolutions(secretResolutions);
            setStep("db-name-conflict");
            return;
        }
        await doImport(secretResolutions, trimmedName);
    }

    //
    // Holds the resolved secret conflict map between the secret-conflict step and the
    // database-name-conflict step, so doImport can be called once at the end.
    //
    const [pendingSecretResolutions, setPendingSecretResolutions] = useState<Record<string, IConflictResolution>>({});

    //
    // Proceeds with the import after secret conflicts have been resolved.
    //
    const handleConflictsResolved = useCallback(async () => {
        const resolutions: Record<string, IConflictResolution> = {};
        for (const conflict of conflicts) {
            resolutions[conflict.secretName] = conflict.resolution;
        }
        await proceedAfterSecretConflicts(resolutions);
    }, [conflicts, editedName]);

    //
    // Proceeds with the import after a database-name conflict has been resolved.
    // For Replace: removes the existing entry first then imports under the original name.
    // For Rename: imports under the user's chosen unique name.
    //
    const handleDbNameConflictResolved = useCallback(async () => {
        if (dbNameConflictAction === "replace") {
            if (existingDbName !== undefined) {
                await platform.removeDatabaseEntry(existingDbName);
            }
            await doImport(pendingSecretResolutions, editedName.trim());
            return;
        }

        const trimmedRename = dbNameConflictRename.trim();
        if (trimmedRename.length === 0) {
            setDbNameConflictRenameError('Name is required');
            return;
        }
        const stillCollides = await platform.findDatabase(trimmedRename);
        if (stillCollides) {
            setDbNameConflictRenameError(`A database named "${trimmedRename}" already exists.`);
            return;
        }
        await doImport(pendingSecretResolutions, trimmedRename);
    }, [dbNameConflictAction, dbNameConflictRename, existingDbName, pendingSecretResolutions, editedName, platform]);

    //
    // Performs the actual import with the given secret-conflict resolutions and final name.
    //
    async function doImport(conflictResolutions: Record<string, IConflictResolution>, finalName: string): Promise<void> {
        if (!payload) {
            return;
        }

        const importPayload = {
            ...payload,
            name: finalName,
            description: editedDescription,
            path: editedPath,
            s3Credentials: importS3 ? payload.s3Credentials : undefined,
            encryptionKey: importEncryption ? payload.encryptionKey : undefined,
            geocodingKey: importGeocoding ? payload.geocodingKey : undefined,
        };

        await platform.importSharePayload(importPayload, conflictResolutions);
        setStep("success");
        log.event('Database imported');
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
                                data-id="receive-database-code-input"
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
                                    label={`Import S3 credentials (${payload.s3Credentials.name})`}
                                    checked={importS3}
                                    onChange={event => setImportS3(event.target.checked)}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {payload.encryptionKey && (
                                <Checkbox
                                    label={`Import encryption key (${payload.encryptionKey.name})`}
                                    checked={importEncryption}
                                    onChange={event => setImportEncryption(event.target.checked)}
                                    sx={{ mb: 1 }}
                                />
                            )}

                            {payload.geocodingKey && (
                                <Checkbox
                                    label={`Import geocoding key (${payload.geocodingKey.name})`}
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

                    {step === "db-name-conflict" && (
                        <>
                            <Alert color="warning" sx={{ mb: 2 }}>
                                A database named "{editedName.trim()}" already exists. Choose what to do.
                            </Alert>

                            <Select
                                value={dbNameConflictAction}
                                onChange={(_event, value) => {
                                    setDbNameConflictAction(value as DbNameConflictAction);
                                    setDbNameConflictRenameError(undefined);
                                }}
                                sx={{ mb: 2 }}
                            >
                                <Option value="replace">Replace existing — removes the existing entry then imports the new one</Option>
                                <Option value="rename">Save with a different name</Option>
                            </Select>

                            {dbNameConflictAction === "rename" && (
                                <FormControl error={dbNameConflictRenameError !== undefined}>
                                    <FormLabel>New database name</FormLabel>
                                    <Input
                                        value={dbNameConflictRename}
                                        onChange={event => {
                                            setDbNameConflictRename(event.target.value);
                                            setDbNameConflictRenameError(undefined);
                                        }}
                                    />
                                    {dbNameConflictRenameError && (
                                        <Typography level="body-sm" color="danger" sx={{ mt: 0.5 }}>
                                            {dbNameConflictRenameError}
                                        </Typography>
                                    )}
                                </FormControl>
                            )}
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
                                data-id="receive-database-start-button"
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
                                data-id="receive-database-save-button"
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

                    {step === "db-name-conflict" && (
                        <>
                            <Button variant="plain" onClick={() => setStep("review")}>Cancel</Button>
                            <Button
                                data-id="receive-database-name-conflict-continue"
                                onClick={() => { handleDbNameConflictResolved().catch(err => log.exception("Import error:", err as Error)); }}
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
