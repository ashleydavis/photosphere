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
// Props for the ConnectDatabaseDialog component.
//
export interface IConnectDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The database being connected to a remote.
    entry: IDatabaseEntry;

    // Called when the dialog should close.
    onClose: () => void;
}

//
// Where the connect flow has got to.
//
type ConnectStep = "configure" | "running" | "success" | "error";

//
// Connects a database to a remote one.
//
// The remote may be empty, may hold an unrelated database, or may already be this one; the task
// works out which and does the right thing, so this dialog asks only where the remote is. What comes
// back says how much was pushed and how much the remote already had, because "nothing was pushed"
// and "everything was pushed" look the same from outside and mean very different things.
//
export function ConnectDatabaseDialog({ open, entry, onClose }: IConnectDatabaseDialogProps) {
    const uuidGenerator = useUuidGenerator();

    const [remotePath, setRemotePath] = useState('');
    const [step, setStep] = useState<ConnectStep>("configure");
    const [errorMessage, setErrorMessage] = useState('');
    const [pushedCount, setPushedCount] = useState(0);
    const [alreadyPresentCount, setAlreadyPresentCount] = useState(0);

    //
    // Runs the consolidation task and reports what it did.
    //
    async function connect(): Promise<void> {
        setStep("running");
        setErrorMessage('');

        const queue = new TaskQueue(uuidGenerator, `connect-${entry.path}`);
        try {
            const taskId = queue.addTask("consolidate-database", {
                databasePath: entry.path,
                remotePath: remotePath.trim(),
                sessionId: uuidGenerator.generate(),
            });
            const taskResult = await queue.awaitTask(taskId);

            if (!taskResult || taskResult.status !== TaskStatus.Succeeded) {
                setErrorMessage(taskResult?.errorMessage || 'The connection could not be completed.');
                setStep("error");
                log.event('Connect to remote failed');
                return;
            }

            const outputs = taskResult.outputs as { pushedCount: number, alreadyPresentCount: number };
            setPushedCount(outputs?.pushedCount ?? 0);
            setAlreadyPresentCount(outputs?.alreadyPresentCount ?? 0);
            setStep("success");
            log.event('Connected to remote');
        }
        catch (error: any) {
            setErrorMessage(error.message || String(error));
            setStep("error");
            log.event('Connect to remote failed');
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
                    connect().catch(error => log.exception('Failed to connect to the remote', error as Error));
                },
                step !== "configure" || remotePath.trim().length === 0
            )}
            data-id="connect-database-dialog"
            >
            <DialogTitle>Connect to remote</DialogTitle>
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
                                data-id="connect-remote-path-input"
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
                        <Typography level="body-sm">Connecting...</Typography>
                    </Box>
                }

                {step === "success"
                    && <Alert color="success" data-id="connect-database-success">
                        <Box>
                            <Typography level="body-sm">Connected to {remotePath}.</Typography>
                            <Typography level="body-sm">Photos uploaded: {pushedCount}</Typography>
                            <Typography level="body-sm">Already on the remote: {alreadyPresentCount}</Typography>
                        </Box>
                    </Alert>
                }

                {step === "error"
                    && <Alert color="danger" data-id="connect-database-error">
                        {errorMessage}
                    </Alert>
                }
            </DialogContent>
            <DialogActions>
                {step === "configure"
                    && <Button
                        data-id="connect-database-confirm"
                        disabled={remotePath.trim().length === 0}
                        onClick={() => {
                            connect().catch(error => log.exception('Failed to connect to the remote', error as Error));
                        }}
                        >
                        Connect
                    </Button>
                }
                <Button variant="plain" data-id="connect-database-close" onClick={close}>
                    {step === "success" ? 'Done' : 'Cancel'}
                </Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
