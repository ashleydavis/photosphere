import React, { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import DialogActions from "@mui/material/DialogActions";
import DialogContent from "@mui/material/DialogContent";
import DialogTitle from "@mui/material/DialogTitle";
import IconButton from "@mui/material/IconButton";
import Typography from "@mui/material/Typography";
import Close from "@mui/icons-material/Close";
import { ResponsiveDialog } from "./responsive-dialog";
import { useJobs } from "../context/jobs-context";
import { formatElapsed } from "../lib/jobs";
import { useElapsedTick } from "../lib/use-elapsed-tick";
import { useIsMobile } from "../lib/use-is-mobile";
import { DialogIconBadge } from "./dialog-icon-badge";
import { DialogSection } from "./dialog-section";

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
    const isMobile = useIsMobile();

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

    //
    // Stop all is the dialog's dangerous action, so it sits at the right end of the row on a
    // desktop, apart from Close. On a mobile the actions stack with the last on top, so it goes
    // first there, leaving Close on top within reach and Stop all under it.
    //
    const stopAll = canCancelAny
        && <Button
            data-id="jobs-cancel-all-button"
            variant="outlined"
            color="error"
            size={isMobile ? "medium" : "small"}
            onClick={() => setPendingCancel({ jobId: undefined, what: jobs.length === 1 ? "this job" : `all ${jobs.length} jobs` })}
            >
            Stop all
        </Button>;

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
            <DialogTitle>
                <DialogIconBadge icon={<i className={pendingCancel ? "fa-solid fa-stop" : "fa-solid fa-bars-progress"} />} danger={pendingCancel !== undefined} />
                Background jobs
            </DialogTitle>

            {pendingCancel
                && <>
                    <DialogContent>
                        <Typography variant="body1" data-id="jobs-cancel-confirm-message">
                            Stop {pendingCancel.what}?
                        </Typography>
                        <Typography
                            variant="body2"
                            sx={{
                                marginTop: 'var(--space-2)',
                                color: 'var(--color-text-muted)',
                            }}
                            >
                            Work already finished is kept. Whatever is still in progress is abandoned.
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button
                            data-id="jobs-cancel-confirm-no"
                            variant="outlined"
                            onClick={() => setPendingCancel(undefined)}
                            >
                            Keep running
                        </Button>
                        <Button
                            data-id="jobs-cancel-confirm-yes"
                            variant="outlined"
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
                            && <Box
                                sx={{
                                    display: 'flex',
                                    flexDirection: 'column',
                                    alignItems: 'center',
                                    gap: 'var(--space-3)',
                                    padding: 'var(--space-6) 0px',
                                    color: 'var(--color-text-muted)',
                                }}
                                >
                                <Box
                                    component="i"
                                    className="fa-solid fa-circle-check"
                                    aria-hidden={true}
                                    sx={{
                                        fontSize: 'var(--text-2xl)',
                                        color: 'var(--color-success)',
                                    }}
                                    />
                                <Typography variant="body2" data-id="jobs-dialog-empty">
                                    Nothing is running in the background.
                                </Typography>
                            </Box>
                        }

                        {jobs.length > 0
                            && <DialogSection heading="">
                                {jobs.map(job => (
                                    <Box
                                        key={job.id}
                                        data-id={`job-row-${job.id}`}
                                        sx={{
                                            display: 'flex',
                                            alignItems: 'center',
                                            gap: 'var(--space-3)',
                                            padding: 'var(--space-3)',
                                            //
                                            // A line between rows, so the Stop button at the end of one row
                                            // cannot be read as belonging to the row above or below it.
                                            // Stopping the wrong job is not undoable.
                                            //
                                            '& + &': {
                                                borderTop: '1px solid var(--color-border)',
                                            },
                                        }}
                                        >
                                        {/*
                                            Deliberately not the ring the navbar spins, nor the one used
                                            for syncing, so a glance tells them apart.
                                        */}
                                        <Box
                                            component="i"
                                            className="fa-solid fa-spinner fa-spin"
                                            aria-hidden={true}
                                            sx={{
                                                flex: 'none',
                                                width: 'var(--icon-md)',
                                                fontSize: 'var(--icon-md)',
                                                textAlign: 'center',
                                                color: 'var(--color-text-muted)',
                                            }}
                                            />

                                        <Box
                                            sx={{
                                                flexGrow: 1,
                                                minWidth: 0,
                                            }}
                                            >
                                            <Typography
                                                variant="body2"
                                                sx={{
                                                    fontWeight: 'var(--weight-medium)',
                                                }}
                                                >
                                                {job.name}
                                            </Typography>
                                            {job.progressMessage
                                                && <Typography
                                                    variant="caption"
                                                    component="p"
                                                    sx={{
                                                        marginTop: 'var(--space-1)',
                                                        color: 'var(--color-text-muted)',
                                                    }}
                                                    >
                                                    {job.progressMessage}
                                                </Typography>
                                            }
                                        </Box>

                                        <Typography
                                            variant="caption"
                                            sx={{
                                                color: 'var(--color-text-muted)',
                                                whiteSpace: 'nowrap',
                                                fontVariantNumeric: 'tabular-nums',
                                            }}
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
                                                sx={{
                                                    borderColor: 'var(--color-danger)',
                                                }}
                                                onClick={() => setPendingCancel({ jobId: job.id, what: `"${job.name}"` })}
                                                >
                                                <Close
                                                    sx={{
                                                        fontSize: 'var(--icon-md)',
                                                    }}
                                                    />
                                            </IconButton>
                                        }
                                    </Box>
                                ))}
                            </DialogSection>
                        }
                    </DialogContent>

                    <DialogActions>
                        {isMobile && stopAll}
                        <Button data-id="jobs-dialog-close" variant="contained" onClick={onClose}>Close</Button>
                        {!isMobile && stopAll}
                    </DialogActions>
                </>
            }
        </ResponsiveDialog>
    );
}
