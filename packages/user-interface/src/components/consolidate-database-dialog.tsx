import React, { useState } from 'react';
import { log } from 'utils';
import { TaskQueue, TaskStatus } from 'task-queue';
import { useUuidGenerator } from '../context/uuid-generator-context';
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
import Box from '@mui/joy/Box';
import { type IDatabaseEntry } from '../context/platform-context';
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
            data-id="consolidate-database-dialog"
            >
            <DialogTitle>Consolidate into remote</DialogTitle>
            <DialogContent>
                {step === "configure"
                    && <>
                        <Typography level="body-sm" sx={{ mb: 2 }}>
                            Keeps a copy of "{entry.name}" on a remote. If the remote already holds a
                            different database, the two are joined and nothing it already has is
                            uploaded again.
                        </Typography>
                        <FormControl>
                            <FormLabel>Remote path</FormLabel>
                            <Input
                                data-id="consolidate-remote-path-input"
                                value={remotePath}
                                placeholder="/path/to/backup or s3:bucket:/prefix"
                                onChange={event => setRemotePath(event.target.value)}
                            />
                        </FormControl>
                    </>
                }

                {step === "running"
                    && <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, py: 2 }}>
                        <CircularProgress size="sm" />
                        <Typography level="body-sm">Consolidating...</Typography>
                    </Box>
                }

                {step === "success"
                    && <Alert color="success" data-id="consolidate-database-success">
                        <Box>
                            <Typography level="body-sm">Consolidated into {remotePath}.</Typography>
                            <Typography level="body-sm">Photos uploaded: {pushedCount}</Typography>
                            <Typography level="body-sm">Already on the remote: {alreadyPresentCount}</Typography>
                        </Box>
                    </Alert>
                }

                {step === "error"
                    && <Alert color="danger" data-id="consolidate-database-error">
                        {errorMessage}
                    </Alert>
                }
            </DialogContent>
            <DialogActions>
                {step === "configure"
                    && <Button
                        data-id="consolidate-database-confirm"
                        disabled={remotePath.trim().length === 0}
                        onClick={() => {
                            consolidate().catch(error => log.exception("Failed to consolidate into the remote", error as Error));
                        }}
                        >
                        Consolidate
                    </Button>
                }
                <Button variant="plain" data-id="consolidate-database-close" onClick={close}>
                    {step === "success" ? 'Done' : 'Cancel'}
                </Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
