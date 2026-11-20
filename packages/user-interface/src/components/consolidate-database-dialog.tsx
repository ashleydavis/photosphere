import React, { useState } from 'react';
import { log } from 'utils';
import { TaskQueue, TaskStatus } from 'task-queue';
import { useUuidGenerator } from '../context/uuid-generator-context';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import Typography from '@mui/material/Typography';
import Alert from '@mui/material/Alert';
import CircularProgress from '@mui/material/CircularProgress';
import Box from '@mui/material/Box';
import Select from '@mui/material/Select';
import MenuItem from '@mui/material/MenuItem';
import { type IDatabaseEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';

//
// Props for the ConsolidateDatabaseDialog component.
//
export interface IConsolidateDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The database being joined to a remote.
    entry: IDatabaseEntry;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Where the consolidation has got to.
//
type ConsolidateStep = "configure" | "running" | "success" | "error";

//
// Joins a database to a remote one so the two can sync.
//
// The remote may be empty, may hold an unrelated database, or may already be this one; the task
// works out which and does the right thing, so this dialog asks only where the remote is. What comes
// back says how much was pushed and how much the remote already had, because "nothing was pushed"
// and "everything was pushed" look the same from outside and mean very different things.
//
export function ConsolidateDatabaseDialog({ open, entry, onClose }: IConsolidateDatabaseDialogProps) {
    const uuidGenerator = useUuidGenerator();
    const { dbs } = useApp();

    //
    // The databases that can be picked as the remote: every entry but this one.
    //
    // The remote's credentials are found by matching its path against the database list, so a typed
    // path that differs by one character finds no entry and gets no credentials. Picking from the list
    // cannot produce that. The field stays typeable, because a remote that is not in the list is still
    // allowed.
    //
    const remoteCandidates = dbs.filter(candidate => candidate.path !== entry.path);

    const [remotePath, setRemotePath] = useState('');
    const [step, setStep] = useState<ConsolidateStep>("configure");
    const [errorMessage, setErrorMessage] = useState('');
    const [pushedCount, setPushedCount] = useState(0);
    const [alreadyPresentCount, setAlreadyPresentCount] = useState(0);

    //
    // Runs the consolidation task and reports what it did.
    //
    async function consolidate(): Promise<void> {
        setStep("running");
        setErrorMessage('');

        const queue = new TaskQueue(uuidGenerator, `consolidate-${entry.path}`);
        try {
            const taskId = queue.addTask("consolidate-database", {
                databasePath: entry.path,
                remotePath: remotePath.trim(),
                sessionId: uuidGenerator.generate(),
            });
            const taskResult = await queue.awaitTask(taskId);

            if (!taskResult || taskResult.status !== TaskStatus.Succeeded) {
                setErrorMessage(taskResult?.errorMessage || 'The consolidation could not be completed.');
                setStep("error");
                log.event("Consolidate into remote failed");
                return;
            }

            const outputs = taskResult.outputs as { pushedCount: number, alreadyPresentCount: number };
            setPushedCount(outputs?.pushedCount ?? 0);
            setAlreadyPresentCount(outputs?.alreadyPresentCount ?? 0);
            setStep("success");
            log.event("Consolidated into remote");
        }
        catch (error: any) {
            setErrorMessage(error.message || String(error));
            setStep("error");
            log.event("Consolidate into remote failed");
        }
        finally {
            queue.shutdown();
        }
    }

    //
    // Closes the dialog and puts it back to its starting state, so reopening it does not show the
    // last run's outcome.
    //
    function close(): void {
        setStep("configure");
        setRemotePath('');
        setErrorMessage('');
        onClose();
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={close}
            minWidth={420}
            maxWidth={560}
            onKeyDown={createDialogKeyHandler(
                () => {
                    consolidate().catch(error => log.exception("Failed to consolidate into the remote", error as Error));
                },
                step !== "configure" || remotePath.trim().length === 0
            )}
            dataId="consolidate-database-dialog"
            >
            <DialogTitle>Consolidate into remote</DialogTitle>
            <DialogContent>
                {step === "configure"
                    && <>
                        <Typography variant="body2" sx={{ mb: 2 }}>
                            Keeps a copy of "{entry.name}" on a remote. If the remote already holds a
                            different database, the two are joined and nothing it already has is
                            uploaded again.
                        </Typography>
                        {/* The picker sits outside the FormControl, not beside the input inside it: a
                            FormControl takes only one input component, and a Select is one. */}
                        <Box sx={{ display: 'flex', gap: 1, alignItems: 'flex-end' }}>
                            <FormControl sx={{ flexGrow: 1 }}>
                                <FormLabel>Remote path</FormLabel>
                                <OutlinedInput
                                    size="small"
                                    data-id="consolidate-remote-path-input"
                                    value={remotePath}
                                    placeholder="/path/to/backup or s3:bucket/prefix"
                                    onChange={event => setRemotePath(event.target.value)}
                                />
                            </FormControl>
                            {remoteCandidates.length > 0
                                && <Select
                                    sx={{ minWidth: 160 }}
                                    size="small"
                                    value=""
                                    displayEmpty
                                    renderValue={() => 'Choose…'}
                                    onChange={event => {
                                        if (event.target.value) {
                                            setRemotePath(event.target.value);
                                        }
                                    }}
                                    data-id="consolidate-remote-select"
                                >
                                    {remoteCandidates.map(candidate => (
                                        <MenuItem
                                            data-id={`consolidate-remote-option-${candidate.name}`}
                                            key={candidate.path}
                                            value={candidate.path}
                                            >
                                            {candidate.name}
                                        </MenuItem>
                                    ))}
                                </Select>
                            }
                        </Box>
                    </>
                }

                {step === "running"
                    && <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, py: 2 }}>
                        <CircularProgress size={24} />
                        <Typography variant="body2">Consolidating...</Typography>
                    </Box>
                }

                {step === "success"
                    && <Alert severity="success" data-id="consolidate-database-success">
                        <Box>
                            <Typography variant="body2">Consolidated into {remotePath}.</Typography>
                            <Typography variant="body2">Photos uploaded: {pushedCount}</Typography>
                            <Typography variant="body2">Already on the remote: {alreadyPresentCount}</Typography>
                        </Box>
                    </Alert>
                }

                {step === "error"
                    && <Alert severity="error" data-id="consolidate-database-error">
                        {errorMessage}
                    </Alert>
                }
            </DialogContent>
            <DialogActions>
                {step === "configure"
                    && <Button
                        data-id="consolidate-database-confirm"
                        variant="contained"
                        disabled={remotePath.trim().length === 0}
                        onClick={() => {
                            consolidate().catch(error => log.exception("Failed to consolidate into the remote", error as Error));
                        }}
                        >
                        Consolidate
                    </Button>
                }
                <Button variant="text" data-id="consolidate-database-close" onClick={close}>
                    {step === "success" ? 'Done' : 'Cancel'}
                </Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
