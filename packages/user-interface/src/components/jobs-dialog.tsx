import React, { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import DialogActions from "@mui/material/DialogActions";
import DialogContent from "@mui/material/DialogContent";
import DialogTitle from "@mui/material/DialogTitle";
import Divider from "@mui/material/Divider";
import IconButton from "@mui/material/IconButton";
import Typography from "@mui/material/Typography";
import Close from "@mui/icons-material/Close";
import { ResponsiveDialog } from "./responsive-dialog";
import { useJobs } from "../context/jobs-context";
import { formatElapsed } from "../lib/jobs";
import { useElapsedTick } from "../lib/use-elapsed-tick";

//
// What the user has asked to stop and is being asked to confirm.
//
interface IPendingCancel {
    //
    // The job to stop, or undefined to stop every job that can be stopped.
    //
    jobId: string | undefined;

    //
    // What the confirmation calls the thing being stopped.
    //
    what: string;
}

export interface IJobsDialogProps {
    //
    // Whether the dialog is visible.
    //
    open: boolean;

    //
    // Called when the dialog should close.
    //
    onClose: () => void;
}

//
// Shows the background work running right now, and offers to stop it.
//
// A modal on a desktop and a sheet on a mobile, opened from the navbar spinner. It lives here rather
// than in the sidebar because the sidebar is a navigation menu and this is not navigation: it is a
// place to look at what is happening and stop it.
//
export function JobsDialog({ open, onClose }: IJobsDialogProps) {
    const { jobs, cancelJob, cancelAllJobs, canCancelAny } = useJobs();
    const now = useElapsedTick(open && jobs.length > 0);

    const [pendingCancel, setPendingCancel] = useState<IPendingCancel | undefined>(undefined);

    //
    // Drop a half-asked question when the dialog closes, so reopening it does not resume a
    // confirmation the user walked away from.
    //
    useEffect(() => {
        if (!open) {
            setPendingCancel(undefined);
        }
    }, [open]);

    //
    // Nothing left to confirm once the job in question has finished on its own.
    //
    useEffect(() => {
        if (pendingCancel?.jobId && !jobs.some(job => job.id === pendingCancel.jobId)) {
            setPendingCancel(undefined);
        }
    }, [jobs, pendingCancel]);

    function confirmCancel(): void {
        if (!pendingCancel) {
            return;
        }

        if (pendingCancel.jobId) {
            cancelJob(pendingCancel.jobId);
        }
        else {
            cancelAllJobs();
        }
        setPendingCancel(undefined);
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={420}
            maxWidth={560}
            dataId="jobs-dialog"
            >
            <DialogTitle>Background jobs</DialogTitle>

            {pendingCancel
                && <>
                    <DialogContent>
                        <Typography variant="body1" data-id="jobs-cancel-confirm-message">
                            Stop {pendingCancel.what}?
                        </Typography>
                        <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
                            Work already finished is kept. Whatever is still in progress is abandoned.
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button
                            data-id="jobs-cancel-confirm-no"
                            variant="text"
                            onClick={() => setPendingCancel(undefined)}
                            >
                            Keep running
                        </Button>
                        <Button
                            data-id="jobs-cancel-confirm-yes"
                            variant="contained"
                            color="error"
                            onClick={confirmCancel}
                            >
                            Stop
                        </Button>
                    </DialogActions>
                </>
            }

            {!pendingCancel
                && <>
                    <DialogContent>
                        {jobs.length === 0
                            && <Typography variant="body2" color="text.secondary" data-id="jobs-dialog-empty">
                                Nothing is running in the background.
                            </Typography>
                        }

                        <Box sx={{ display: 'flex', flexDirection: 'column', py: 1 }}>
                            {jobs.map((job, jobIndex) => (
                                <React.Fragment key={job.id}>
                                    {/*
                                        A line between rows, so the Stop button at the end of one row
                                        cannot be read as belonging to the row above or below it.
                                        Stopping the wrong job is not undoable.
                                    */}
                                    {jobIndex > 0 && <Divider sx={{ my: 1.5 }} />}

                                <Box
                                    data-id={`job-row-${job.id}`}
                                    sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}
                                    >
                                    {/*
                                        Deliberately not the ring the navbar spins, nor the one used
                                        for syncing, so a glance tells them apart.
                                    */}
                                    <i
                                        className="fa-solid fa-spinner fa-spin"
                                        style={{ opacity: 0.7, width: 16, textAlign: 'center' }}
                                        />

                                    <Box sx={{ flexGrow: 1, minWidth: 0 }}>
                                        <Typography variant="body2">
                                            {job.name}
                                        </Typography>
                                        {job.progressMessage
                                            && <Typography variant="caption" component="p" sx={{ color: 'text.secondary', mt: 0.25 }}>
                                                {job.progressMessage}
                                            </Typography>
                                        }
                                    </Box>

                                    <Typography
                                        variant="caption"
                                        sx={{ color: 'text.secondary', whiteSpace: 'nowrap' }}
                                        data-id={`job-elapsed-${job.id}`}
                                        >
                                        {formatElapsed(now - job.startedAt)}
                                    </Typography>

                                    {job.cancelSource
                                        && <IconButton
                                            data-id={`job-cancel-${job.id}`}
                                            size="small"
                                            color="error"
                                            aria-label="Stop job"
                                            title="Stop"
                                            onClick={() => setPendingCancel({ jobId: job.id, what: `"${job.name}"` })}
                                            >
                                            <Close fontSize="small" />
                                        </IconButton>
                                    }
                                </Box>
                                </React.Fragment>
                            ))}
                        </Box>
                    </DialogContent>

                    <DialogActions>
                        {canCancelAny
                            && <Button
                                data-id="jobs-cancel-all-button"
                                variant="text"
                                color="error"
                                onClick={() => setPendingCancel({ jobId: undefined, what: jobs.length === 1 ? "this job" : `all ${jobs.length} jobs` })}
                                >
                                Stop all
                            </Button>
                        }
                        <Button data-id="jobs-dialog-close" variant="contained" onClick={onClose}>Close</Button>
                    </DialogActions>
                </>
            }
        </ResponsiveDialog>
    );
}
