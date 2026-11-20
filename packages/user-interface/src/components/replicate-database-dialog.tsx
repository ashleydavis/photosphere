import React, { useCallback, useEffect, useState } from 'react';
import { log } from 'utils';
import { useUuidGenerator } from '../context/uuid-generator-context';
import { replicateDatabase } from '../lib/replicate-database';
import type { IReplicateDatabaseData } from 'api/src/lib/replicate-database.types';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import FormControlLabel from '@mui/material/FormControlLabel';
import Radio from '@mui/material/Radio';
import RadioGroup from '@mui/material/RadioGroup';
import Select from '@mui/material/Select';
import MenuItem from '@mui/material/MenuItem';
import Typography from '@mui/material/Typography';
import Box from '@mui/material/Box';
import Alert from '@mui/material/Alert';
import CircularProgress from '@mui/material/CircularProgress';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { S3BrowserModal } from './s3-browser-modal';
import { ConfigureSecretsModal } from './configure-secrets-modal';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import ContentCopyIcon from '@mui/icons-material/ContentCopy';
import FolderOpenIcon from '@mui/icons-material/FolderOpen';
import { DialogIconBadge } from './dialog-icon-badge';
import { CARD_SX, cardRowSx, FIELD_LABEL_SX } from './create-database-modal';
import { applyDestinationTypeChange, emptyReplicateFormState, type IReplicateFormState, type ReplicateMode } from '../lib/replicate-form';

//
// Props for the ReplicateDatabaseDialog component.
//
export interface IReplicateDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The source database entry to replicate from.
    sourceEntry: IDatabaseEntry;

    // All available encryption-key shared secrets the user can pick for the destination.
    encryptionSecrets: ISharedSecretEntry[];

    // All available S3-credential shared secrets the user can pick for the destination.
    s3Secrets: ISharedSecretEntry[];

    // All available geocoding-api-key shared secrets the user can pick for the destination.
    geocodingSecrets: ISharedSecretEntry[];

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the replicate flow.
//
type ReplicateStep = "configure" | "running" | "success" | "error";

//
// Dialog for replicating a database to a new destination via the worker pool.
// Lets the user pick a destination path, choose between Partial and Full mode,
// and select destination encryption and (when applicable) S3 credentials.
//
// The dialog can be closed while the replication is running: "Run in background" hands it over to
// the job list in the right sidebar, which is where its progress is shown from then on and where it
// can be cancelled. Closing does not cancel anything; the task was queued against the worker pool
// and knows nothing about this dialog.
//
export function ReplicateDatabaseDialog({ open, sourceEntry, encryptionSecrets, s3Secrets, geocodingSecrets, onClose }: IReplicateDatabaseDialogProps) {
    const platform = usePlatform();
    const uuidGenerator = useUuidGenerator();

    const [step, setStep] = useState<ReplicateStep>("configure");
    const [form, setForm] = useState<IReplicateFormState>(emptyReplicateFormState());
    const [progress, setProgress] = useState<string>("");
    const [errorMessage, setErrorMessage] = useState<string>("");
    const [s3BrowserOpen, setS3BrowserOpen] = useState(false);
    const [secretsModalOpen, setSecretsModalOpen] = useState(false);

    useEffect(() => {
        if (open) {
            setStep("configure");
            setForm(emptyReplicateFormState());
            setProgress("");
            setErrorMessage("");
        }
    }, [open, sourceEntry]);

    const isS3Dest = form.storageType === 's3';
    const browseDisabled = isS3Dest && !form.secrets.s3Key;

    // A mobile has no folder dialog for a database location: the user types a name for the copy into the path field instead.
    const showBrowse = isS3Dest || platform.platformKind === "desktop";
    const startDisabled = form.destPath.trim().length === 0
        || form.destPath.trim() === sourceEntry.path
        || (isS3Dest && !form.secrets.s3Key);

    //
    // Short summary of the selected destination secrets, shown next to the Configure secrets button.
    //
    function summariseDestSecrets(): string {
        const parts: string[] = [];
        if (form.secrets.s3Key) parts.push(`S3: ${form.secrets.s3Key}`);
        if (form.secrets.encryptionKey) parts.push(`Encryption: ${form.secrets.encryptionKey}`);
        if (form.secrets.geocodingKey) parts.push(`Geocoding: ${form.secrets.geocodingKey}`);
        if (parts.length === 0) {
            return isS3Dest ? 'S3 credentials required' : 'No secrets configured';
        }
        return parts.join(' · ');
    }

    //
    // Opens the native folder picker (filesystem) or the S3 browser modal (s3:) and writes the
    // chosen path back to the form. Browsing S3 requires a selected S3 credential entry.
    //
    const handleBrowse = useCallback(async () => {
        if (form.storageType === 's3') {
            setS3BrowserOpen(true);
            return;
        }
        const chosen = await platform.pickFolder();
        if (chosen) {
            setForm(prev => ({ ...prev, destPath: chosen }));
        }
    }, [platform, form.storageType]);

    //
    // Calls the shared replicateDatabase wrapper, which queues the task and waits for completion.
    // The promise is owned here and is unaffected by the dialog being closed, so a replication run
    // in the background still records its outcome.
    //
    const handleStart = useCallback(async () => {
        setStep("running");
        setProgress("Starting replication...");

        const taskData: IReplicateDatabaseData = {
            sourcePath: sourceEntry.path,
            destPath: form.destPath.trim(),
            destEncryptionKey: form.secrets.encryptionKey,
            destS3Key: form.secrets.s3Key,
            partial: form.mode === "partial",
            force: false,
        };

        try {
            await replicateDatabase(uuidGenerator, taskData, setProgress);
            // Log completion so it is observable on every platform (the desktop main process logs the
            // same line for its own path); the smoke test waits for it.
            const destName = taskData.destPath.split(/[\\/]/).filter(Boolean).pop() ?? taskData.destPath;
            log.info(`Replication completed for "${destName}"`);
            setStep("success");
        }
        catch (err) {
            log.exception('Replication error:', err as Error);
            setErrorMessage(err instanceof Error ? err.message : String(err));
            setStep("error");
        }
    }, [sourceEntry, form, uuidGenerator]);

    //
    // The primary action for the current step: start replication while configuring,
    // or close once it has finished (success or error).
    //
    async function handleDialogConfirm(): Promise<void> {
        if (step === "configure") {
            await handleStart();
        }
        else if (step === "success" || step === "error") {
            onClose();
        }
    }

    // Enter is disabled while running, and while the configure form is incomplete.
    const dialogConfirmDisabled = step === "configure" ? startDisabled : step === "running";

    return (
        <>
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={520}
            maxWidth={720}
            dataId="replicate-database-dialog"
            onKeyDown={createDialogKeyHandler(handleDialogConfirm, dialogConfirmDisabled)}
            >
            <DialogTitle>
                <DialogIconBadge icon={<ContentCopyIcon />} danger={false} />
                Replicate Database
            </DialogTitle>
            <DialogContent sx={{ overflowX: 'hidden' }}>
                {step === "configure" && (
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 'var(--space-4)',
                            paddingTop: 'var(--space-1)',
                        }}
                        >
                        <Box>
                            <Typography variant="body1">
                                <Box
                                    component="strong"
                                    sx={{
                                        color: 'var(--color-text-muted)',
                                        fontSize: 'var(--text-sm)',
                                        fontWeight: 'var(--weight-bold)',
                                    }}
                                    >
                                    Source:
                                </Box> {sourceEntry.name}
                            </Typography>
                            <Typography
                                variant="body2"
                                sx={{
                                    overflowWrap: 'anywhere',
                                    color: 'var(--color-text-muted)',
                                    fontFamily: 'var(--font-mono)',
                                    fontSize: 'var(--text-sm)',
                                }}
                                >
                                {sourceEntry.path}
                            </Typography>
                        </Box>

                        <FormControl fullWidth>
                            <FormLabel sx={FIELD_LABEL_SX}>Destination type</FormLabel>
                            <Select
                                value={form.storageType}
                                size="small"
                                onChange={event => setForm(prev => applyDestinationTypeChange(prev, event.target.value))}
                                data-id="replicate-dest-type-select"
                            >
                                <MenuItem data-id="replicate-dest-type-option-filesystem" value="filesystem">File system</MenuItem>
                                <MenuItem data-id="replicate-dest-type-option-s3" value="s3">S3</MenuItem>
                            </Select>
                        </FormControl>

                        <FormControl fullWidth>
                            <FormLabel sx={FIELD_LABEL_SX}>Destination secrets</FormLabel>
                            <Box sx={CARD_SX}>
                                <Box sx={cardRowSx(true)}>
                                    <Typography
                                        data-id="replicate-dest-secrets-summary"
                                        variant="body2"
                                        sx={{
                                            minWidth: 0,
                                            overflowWrap: 'anywhere',
                                            color: 'var(--color-text-muted)',
                                            fontSize: 'var(--text-sm)',
                                        }}
                                        >
                                        {summariseDestSecrets()}
                                    </Typography>
                                    <Button
                                        data-id="replicate-configure-secrets-button"
                                        variant="outlined"
                                        size="small"
                                        sx={{
                                            flex: 'none',
                                        }}
                                        onClick={() => setSecretsModalOpen(true)}
                                    >
                                        Configure secrets…
                                    </Button>
                                </Box>
                            </Box>
                        </FormControl>

                        <FormControl fullWidth>
                            <FormLabel sx={FIELD_LABEL_SX}>Destination path</FormLabel>
                            <Box
                                sx={{
                                    display: 'flex',
                                    alignItems: 'stretch',
                                    gap: 'var(--space-2)',
                                }}
                                >
                                <OutlinedInput
                                    size="small"
                                    data-id="replicate-dest-path-input"
                                    sx={{
                                        flexGrow: 1,
                                        fontFamily: 'var(--font-mono)',
                                        fontSize: 'var(--text-sm)',
                                    }}
                                    value={form.destPath}
                                    placeholder={showBrowse ? undefined : 'Type a name for the copy'}
                                    onChange={event => setForm(prev => ({ ...prev, destPath: event.target.value }))}
                                />
                                {showBrowse && (
                                    <Button
                                        data-id="replicate-dest-browse-button"
                                        variant="outlined"
                                        disabled={browseDisabled}
                                        startIcon={<FolderOpenIcon />}
                                        sx={{
                                            flex: 'none',
                                            whiteSpace: 'nowrap',
                                        }}
                                        onClick={() => handleBrowse().catch(err => log.exception('Browse error:', err as Error))}
                                    >
                                        {isS3Dest ? 'Browse S3' : 'Browse'}
                                    </Button>
                                )}
                            </Box>
                        </FormControl>

                        <FormControl fullWidth>
                            <FormLabel sx={FIELD_LABEL_SX}>Mode</FormLabel>
                            <RadioGroup
                                value={form.mode}
                                onChange={event => setForm(prev => ({ ...prev, mode: event.target.value as ReplicateMode }))}
                                sx={{
                                    '& .replicate-mode-hint': {
                                        marginLeft: 'var(--space-8)',
                                        marginBottom: 'var(--space-2)',
                                        color: 'var(--color-text-muted)',
                                        fontSize: 'var(--text-sm)',
                                    },
                                }}
                            >
                                <FormControlLabel
                                    value="partial"
                                    control={<Radio data-id="replicate-mode-partial" size="small" />}
                                    label="Partial"
                                />
                                <Typography variant="caption" className="replicate-mode-hint">
                                    Copies only metadata and structure. Original photos and videos are fetched on demand from the source. Choose this when you want a small, browsable replica.
                                </Typography>
                                <FormControlLabel
                                    value="full"
                                    control={<Radio data-id="replicate-mode-full" size="small" />}
                                    label="Full"
                                />
                                <Typography variant="caption" className="replicate-mode-hint">
                                    Copies everything — every original, display, and thumbnail file. Choose this when you want a complete, standalone copy that does not depend on the source.
                                </Typography>
                            </RadioGroup>
                        </FormControl>

                        <Typography
                            variant="caption"
                            sx={{
                                display: 'block',
                                color: 'var(--color-text-muted)',
                                fontSize: 'var(--text-sm)',
                            }}
                            >
                            To replicate to an existing encrypted database, register it on this page first and the replica will inherit its credentials.
                        </Typography>
                    </Box>
                )}

                {step === "running" && (
                    <>
                        <Box
                            sx={{
                                display: 'flex',
                                alignItems: 'center',
                                gap: 'var(--space-4)',
                                padding: 'var(--space-6) 0',
                            }}
                            >
                            <CircularProgress size="var(--icon-lg)" />
                            <Typography>{progress}</Typography>
                        </Box>
                        <Typography
                            variant="body2"
                            data-id="replicate-background-hint"
                            sx={{
                                color: 'var(--color-text-muted)',
                            }}
                            >
                            Replication runs in the background. You can close this dialog and it will keep going; watch it and stop it from the Background jobs list in the menu.
                        </Typography>
                    </>
                )}

                {step === "success" && (
                    <Alert severity="success">
                        Replication completed. The replica has been added to your databases at {form.destPath}.
                    </Alert>
                )}

                {step === "error" && (
                    <Alert severity="error">
                        {errorMessage}
                    </Alert>
                )}
            </DialogContent>
            <DialogActions>
                {step === "configure" && (
                    <>
                        <Button
                            data-id="replicate-cancel-button"
                            variant="outlined"
                            onClick={onClose}
                        >
                            Cancel
                        </Button>
                        <Button
                            data-id="replicate-start-button"
                            variant="contained"
                            disabled={startDisabled}
                            onClick={() => {
                                handleStart().catch(err => log.exception('Start replication error:', err as Error));
                            }}
                        >
                            Start replication
                        </Button>
                    </>
                )}

                {step === "running" && (
                    <Button
                        data-id="replicate-run-in-background-button"
                        variant="contained"
                        onClick={onClose}
                    >
                        Run in background
                    </Button>
                )}

                {(step === "success" || step === "error") && (
                    <Button data-id="replicate-close-button" variant="contained" onClick={onClose}>Close</Button>
                )}
            </DialogActions>
        </ResponsiveDialog>
        {s3BrowserOpen && form.secrets.s3Key && (
            <S3BrowserModal
                open={true}
                s3Key={form.secrets.s3Key}
                onClose={() => setS3BrowserOpen(false)}
                onSelect={chosenPath => {
                    setS3BrowserOpen(false);
                    setForm(prev => ({ ...prev, destPath: chosenPath }));
                }}
            />
        )}
        <ConfigureSecretsModal
            open={secretsModalOpen}
            initialValue={form.secrets}
            s3Secrets={s3Secrets}
            encryptionSecrets={encryptionSecrets}
            geocodingSecrets={geocodingSecrets}
            onSave={next => {
                setForm(prev => ({ ...prev, secrets: next }));
                setSecretsModalOpen(false);
            }}
            onClose={() => setSecretsModalOpen(false)}
            quickCreateDefaultName={sourceEntry.name}
        />
        </>
    );
}
