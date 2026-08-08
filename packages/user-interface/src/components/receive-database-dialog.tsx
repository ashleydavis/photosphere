import { log } from "utils";
import React, { useState, useEffect, useCallback, useRef } from 'react';
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
import Checkbox from '@mui/joy/Checkbox';
import Box from '@mui/joy/Box';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import type { IConflictResolution } from 'api';
import { usePlatform } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { lanShareErrorMessage } from '../lib/lan-share-error-message';

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
    const { removeDatabase, importSharePayload } = useApp();
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

    // Set when the user cancels a receive that is already waiting for a sender.
    //
    // Cancelling closes the dialog, but the wait for the sender is still in flight and finishes
    // afterwards, reporting that no sender connected. Without this it writes that outcome into a
    // dialog that has already closed and reset itself, leaving it on the error step, so reopening
    // shows the error rather than the code field. A ref rather than state because the in-flight
    // wait needs to read the current value when it resolves, not the one captured when it started.
    const receiveAbandoned = useRef(false);

    // Reset state when the dialog closes, and announce it only once it is open.
    //
    // The reset happens on the way out rather than on the way in so that the dialog is always
    // already showing the code step by the time it becomes visible. Resetting on open cannot do
    // that: an effect runs after the render that opened the dialog, so setting the step there
    // leaves one render in which the dialog is open and still showing whichever step it was on
    // when it was last closed. Reopening after a cancel lands on the waiting step, which has no
    // code field and no Start button, and anything acting on the line below finds neither.
    useEffect(() => {
        if (!open) {
            setStep("enter-code");
            setEnteredCode("");
            setPayload(null);
            setErrorMessage("");
            return;
        }
        log.event('Receive database dialog opened');
    }, [open]);

    //
    // Starts the receiver with the entered code, waits for the sender payload, then moves to review.
    //
    const handleStartReceiving = useCallback(async () => {
        receiveAbandoned.current = false;
        try {
            await platform.startShareReceive(enteredCode);
            setStep("waiting");

            const received = await platform.waitShareReceive();

            // A receive the user cancelled has nothing to report. Its outcome would otherwise land
            // in a dialog that has already closed and reset.
            if (receiveAbandoned.current) {
                return;
            }

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
        }
        catch (err) {
            // Same reason as above: a cancelled receive that fails on its way out is not a failure
            // the user needs telling about, and the dialog it would report into has gone.
            if (receiveAbandoned.current) {
                return;
            }
            // Surface the failure instead of leaving the dialog spinning on "Waiting for sender...".
            log.exception("Receive error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
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

        try {
            const found = await detectConflicts(payload);
            if (found.length > 0) {
                setConflicts(found);
                setStep("conflict");
                return;
            }

            await proceedAfterSecretConflicts({});
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog stuck on the review step.
            log.exception("Import error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
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
        try {
            const resolutions: Record<string, IConflictResolution> = {};
            for (const conflict of conflicts) {
                resolutions[conflict.secretName] = conflict.resolution;
            }
            await proceedAfterSecretConflicts(resolutions);
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog stuck on the conflict step.
            log.exception("Import error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
    }, [conflicts, editedName]);

    //
    // Proceeds with the import after a database-name conflict has been resolved.
    // For Replace: removes the existing entry first then imports under the original name.
    // For Rename: imports under the user's chosen unique name.
    //
    const handleDbNameConflictResolved = useCallback(async () => {
        try {
            if (dbNameConflictAction === "replace") {
                if (existingDbName !== undefined) {
                    await removeDatabase(existingDbName);
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
        }
        catch (err) {
            // Surface the failure instead of leaving the dialog stuck on the conflict step.
            log.exception("Import error:", err as Error);
            setErrorMessage(lanShareErrorMessage(err as Error));
            setStep("error");
        }
    }, [dbNameConflictAction, dbNameConflictRename, existingDbName, pendingSecretResolutions, editedName, platform, removeDatabase]);

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
            path: editedPath.trim(),
            s3Credentials: importS3 ? payload.s3Credentials : undefined,
            encryptionKey: importEncryption ? payload.encryptionKey : undefined,
            geocodingKey: importGeocoding ? payload.geocodingKey : undefined,
        };

        await importSharePayload(importPayload, conflictResolutions);
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
            // Marked before the cancel rather than after, because cancelling is what makes the
            // in-flight wait finish, and it can resolve while this is still awaiting.
            receiveAbandoned.current = true;
            await platform.cancelShareReceive();
        }
        onClose();
    }, [step, platform, onClose]);

    const conflictResolutionInvalid = conflicts.some(
        conflict => conflict.resolution.action === "rename" && !conflict.resolution.newName?.trim()
    );

    //
    // The primary action for the current step, mirroring each step's primary button.
    //
    async function handleDialogConfirm(): Promise<void> {
        if (step === "enter-code") {
            await handleStartReceiving();
        }
        else if (step === "review") {
            await handleSave();
        }
        else if (step === "conflict") {
            await handleConflictsResolved();
        }
        else if (step === "db-name-conflict") {
            await handleDbNameConflictResolved();
        }
        else if (step === "success" || step === "error") {
            onClose();
        }
    }

    // Enter mirrors the enabled state of each step's primary button.
    const dialogConfirmDisabled =
        (step === "enter-code" && !/^\d{4}$/.test(enteredCode))
        || (step === "review" && (!editedName || !editedPath))
        || (step === "conflict" && conflictResolutionInvalid)
        || step === "waiting";

    return (
        <ResponsiveDialog
            open={open}
            onClose={handleCancel}
            minWidth={480}
            maxWidth={600}
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
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
                                onClick={() => { handleStartReceiving(); }}
                            >
                                Start
                            </Button>
                        </>
                    )}

                    {step === "waiting" && (
                        <Button data-id="receive-database-cancel-button" variant="plain" onClick={handleCancel}>Cancel</Button>
                    )}

                    {step === "review" && (
                        <>
                            <Button variant="plain" onClick={handleCancel}>Cancel</Button>
                            <Button
                                data-id="receive-database-save-button"
                                disabled={!editedName || !editedPath}
                                onClick={() => { handleSave(); }}
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
                                onClick={() => { handleConflictsResolved(); }}
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
                                onClick={() => { handleDbNameConflictResolved(); }}
                            >
                                Continue
                            </Button>
                        </>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button data-id="receive-database-close-button" onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
        </ResponsiveDialog>
    );
}
