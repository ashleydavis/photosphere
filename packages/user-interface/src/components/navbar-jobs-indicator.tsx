import React from "react";
import Chip from "@mui/joy/Chip";
import CircularProgress from "@mui/joy/CircularProgress";
import { useJobs } from "../context/jobs-context";
import { describeJobsIndicator } from "../lib/jobs";

//
// Says how much is running in the background, in the navbar.
//
// Clicking opens the background jobs dialog, where the jobs are listed one by one and can be
// stopped. It is a chip rather than bare text and a spinner because a spinner beside a word reads as
// a status, not a control: it has a filled background, a hover state and a pointer cursor, so it
// looks like the button it is.
//
export function NavbarJobsIndicator() {
    const { jobs } = useJobs();

    const indicator = describeJobsIndicator(jobs);

    return (
        <>
            {indicator
                && <Chip
                    data-id="navbar-jobs-indicator"
                    variant="soft"
                    color="primary"
                    size="sm"
                    title="Show background jobs"
                    onClick={() => window.dispatchEvent(new CustomEvent("photosphere:show-jobs"))}
                    startDecorator={
                        // Always spinning, never filling. This says "something is running", and a
                        // ring creeping round once over a minute reads as a stuck app rather than a
                        // busy one. What each job is doing is in the dialog.
                        <CircularProgress size="sm" />
                    }
                    sx={{
                        mx: 1,
                        cursor: 'pointer',
                        whiteSpace: 'nowrap',
                        // Joy's small chip is sized for a bare word. This one carries a spinner as
                        // well, which sits against the edge without room made for it.
                        '--Chip-paddingInline': '12px',
                        '--Chip-gap': '8px',
                        py: 0.75,
                    }}
                    >
                    {/*
                        Short enough to show at every width, including a phone's, where the longer
                        label it replaced was hidden altogether and left a spinner saying nothing.
                        How long each job has been going is in the dialog, where there is room.
                    */}
                    {indicator.label}
                </Chip>
            }

            {/*
                Machine-readable job count for the smoke tests, so the driver can wait on the number
                of running jobs rather than racing a spinner. Always rendered, so a driver can wait
                for it to come back to "0" as well as watch it rise, and taken off-screen rather than
                hidden with display:none, which the driver treats as absent. The same arrangement as
                navbar-sync-state below it.
            */}
            <span
                data-id="navbar-jobs-count"
                style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap' }}
                >
                {jobs.length}
            </span>
        </>
    );
}
