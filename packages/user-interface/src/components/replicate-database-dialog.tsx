import React, { useCallback, useEffect, useState } from 'react';
import { log, RandomUuidGenerator } from 'utils';
import { replicateDatabase } from 'api/src/lib/replicate-database';
import type { IReplicateDatabaseData } from 'api/src/lib/replicate-database.types';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Input from '@mui/joy/Input';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Radio from '@mui/joy/Radio';
import RadioGroup from '@mui/joy/RadioGroup';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import Typography from '@mui/joy/Typography';
import Box from '@mui/joy/Box';
import Alert from '@mui/joy/Alert';
import CircularProgress from '@mui/joy/CircularProgress';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { S3BrowserModal } from './s3-browser-modal';
import { ConfigureSecretsModal, type IDatabaseSecretsSelection } from './configure-secrets-modal';

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

    // Optional callback fired after a new secret has been quick-created inside the Configure
    // Secrets modal. The parent should reload its secret lists.
    onSecretCreated?: () => Promise<void>;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Steps in the replicate flow.
//
type ReplicateStep = "configure" | "running" | "success" | "error";

//
// Replication mode.
//
type ReplicateMode = "partial" | "full";

//
// Destination storage type.
//
type StorageType = "filesystem" | "s3";

//
// Form state for the replicate dialog.
//
interface IReplicateFormState {
    // Selected destination storage type.
    storageType: StorageType;

    // Destination database path (filesystem path or s3:bucket/prefix).
    destPath: string;

    // Selected replication mode.
    mode: ReplicateMode;

    // Vault secret references for the destination (S3, encryption, geocoding).
    secrets: IDatabaseSecretsSelection;
}

//
// Returns an empty form state.
//
function emptyFormState(): IReplicateFormState {
    return {
        storageType: 'filesystem',
        destPath: '',
        mode: 'partial',
        secrets: { s3Key: undefined, encryptionKey: undefined, geocodingKey: undefined },
    };
}

//
// Dialog for replicating a database to a new destination via the worker pool.
// Lets the user pick a destination path, choose between Partial and Full mode,
// and select destination encryption and (when applicable) S3 credentials.
// Cancellation while running is intentionally out of scope for v1; the dialog only
// shows a progress view once the task starts.
//
export function ReplicateDatabaseDialog({ open, sourceEntry, encryptionSecrets, s3Secrets, geocodingSecrets, onSecretCreated, onClose }: IReplicateDatabaseDialogProps) {
    const platform = usePlatform();

    const [step, setStep] = useState<ReplicateStep>("configure");
    const [form, setForm] = useState<IReplicateFormState>(emptyFormState());
    const [progress, setProgress] = useState<string>("");
    const [errorMessage, setErrorMessage] = useState<string>("");
    const [s3BrowserOpen, setS3BrowserOpen] = useState(false);
    const [secretsModalOpen, setSecretsModalOpen] = useState(false);

    useEffect(() => {
        if (open) {
            setStep("configure");
            setForm(emptyFormState());
            setProgress("");
            setErrorMessage("");
        }
    }, [open, sourceEntry]);

    const isS3Dest = form.storageType === 's3';
    const browseDisabled = isS3Dest && !form.secrets.s3Key;
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
    // Cancellation while running is intentionally out of scope for v1.
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
            await replicateDatabase(new RandomUuidGenerator(), taskData, setProgress);
            setStep("success");
        }
        catch (err) {
            log.exception('Replication error:', err as Error);
            setErrorMessage(err instanceof Error ? err.message : String(err));
            setStep("error");
        }
    }, [sourceEntry, form]);

    return (
        <>
        <Modal open={open} onClose={step === "running" ? undefined : onClose}>
            <ModalDialog data-id="replicate-database-dialog" sx={{ minWidth: 520, maxWidth: 720, overflowY: 'auto', overflowX: 'hidden' }}>
                <DialogTitle>Replicate Database</DialogTitle>
                <DialogContent sx={{ overflowX: 'hidden' }}>
                    {step === "configure" && (
                        <>
                            <Typography level="body-md" sx={{ mb: 1 }}>
                                <strong>Source:</strong> {sourceEntry.name}
                            </Typography>
                            <Typography level="body-sm" color="neutral" sx={{ mb: 2 }}>
                                {sourceEntry.path}
                            </Typography>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Destination type</FormLabel>
                                <Select
                                    value={form.storageType}
                                    onChange={(_event, value) => setForm(prev => ({
                                        ...prev,
                                        storageType: (value as StorageType) ?? 'filesystem',
                                        destPath: '',
                                    }))}
                                >
                                    <Option value="filesystem">File system</Option>
                                    <Option value="s3">S3</Option>
                                </Select>
                            </FormControl>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Destination secrets</FormLabel>
                                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                                    <Typography level="body-sm" sx={{ flexGrow: 1 }} color="neutral">
                                        {summariseDestSecrets()}
                                    </Typography>
                                    <Button
                                        data-id="replicate-configure-secrets-button"
                                        variant="outlined"
                                        size="sm"
                                        onClick={() => setSecretsModalOpen(true)}
                                    >
                                        Configure secrets…
                                    </Button>
                                </Box>
                            </FormControl>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Destination path</FormLabel>
                                <Box sx={{ display: 'flex', gap: 1 }}>
                                    <Input
                                        data-id="replicate-dest-path-input"
                                        sx={{ flexGrow: 1 }}
                                        value={form.destPath}
                                        onChange={event => setForm(prev => ({ ...prev, destPath: event.target.value }))}
                                    />
                                    <Button
                                        data-id="replicate-dest-browse-button"
                                        variant="outlined"
                                        disabled={browseDisabled}
                                        onClick={() => handleBrowse().catch(err => log.exception('Browse error:', err as Error))}
                                    >
                                        {isS3Dest ? 'Browse S3' : 'Browse'}
                                    </Button>
                                </Box>
                            </FormControl>

                            <FormControl sx={{ mb: 2 }}>
                                <FormLabel>Mode</FormLabel>
                                <RadioGroup
                                    value={form.mode}
                                    onChange={event => setForm(prev => ({ ...prev, mode: event.target.value as ReplicateMode }))}
                                >
                                    <Radio
                                        data-id="replicate-mode-partial"
                                        value="partial"
                                        label="Partial"
                                    />
                                    <Typography level="body-xs" color="neutral" sx={{ ml: 4, mb: 1 }}>
                                        Copies only metadata and structure. Original photos and videos are fetched on demand from the source. Choose this when you want a small, browsable replica.
                                    </Typography>
                                    <Radio
                                        data-id="replicate-mode-full"
                                        value="full"
                                        label="Full"
                                    />
                                    <Typography level="body-xs" color="neutral" sx={{ ml: 4 }}>
                                        Copies everything — every original, display, and thumbnail file. Choose this when you want a complete, standalone copy that does not depend on the source.
                                    </Typography>
                                </RadioGroup>
                            </FormControl>

                            <Typography level="body-xs" color="neutral" sx={{ mt: 2 }}>
                                To replicate to an existing encrypted database, register it on this page first and the replica will inherit its credentials.
                            </Typography>
                        </>
                    )}

                    {step === "running" && (
                        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, py: 3 }}>
                            <CircularProgress size="sm" />
                            <Typography>{progress}</Typography>
                        </Box>
                    )}

                    {step === "success" && (
                        <Alert color="success">
                            Replication completed. The replica has been added to your databases at {form.destPath}.
                        </Alert>
                    )}

                    {step === "error" && (
                        <Alert color="danger">
                            {errorMessage}
                        </Alert>
                    )}
                </DialogContent>
                <DialogActions>
                    {step === "configure" && (
                        <>
                            <Button
                                data-id="replicate-cancel-button"
                                variant="plain"
                                onClick={onClose}
                            >
                                Cancel
                            </Button>
                            <Button
                                data-id="replicate-start-button"
                                disabled={startDisabled}
                                onClick={() => {
                                    handleStart().catch(err => log.exception('Start replication error:', err as Error));
                                }}
                            >
                                Start replication
                            </Button>
                        </>
                    )}

                    {(step === "success" || step === "error") && (
                        <Button data-id="replicate-close-button" onClick={onClose}>Close</Button>
                    )}
                </DialogActions>
            </ModalDialog>
        </Modal>
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
            onSecretCreated={onSecretCreated}
            quickCreateDefaultName={sourceEntry.name}
        />
        </>
    );
}
