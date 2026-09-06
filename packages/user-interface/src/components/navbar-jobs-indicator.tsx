import React from "react";
import Chip from "@mui/joy/Chip";
import CircularProgress from "@mui/joy/CircularProgress";
import { useJobs } from "../context/jobs-context";
import { describeJobsIndicator } from "../lib/jobs";
import { useIsMobile } from "../lib/use-is-mobile";

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
    const isMobile = useIsMobile();

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
                    sx={{
                        mx: 1,
                        cursor: 'pointer',
                        whiteSpace: 'nowrap',
                        // Joy's small chip is sized for a bare word. This one carries a spinner as
                        // well, which sits against the edge without room made for it.
                        '--Chip-paddingInline': isMobile ? '8px' : '12px',
                        '--Chip-gap': '8px',
                        py: 0.75,
                    }}
                    >
                    {/*
                        Always spinning, never filling. This says "something is running", and a ring
                        creeping round once over a minute reads as a stuck app rather than a busy one.
                    */}
                    <CircularProgress size="sm" />

                    {/*
                        The count is desktop only. A phone's navbar has no room to spare, and the
                        spinner alone still says work is happening; how much and what it is are one
                        tap away in the dialog.
                    */}
                    {!isMobile
                        && <span style={{ marginLeft: 8 }}>{indicator.label}</span>
                    }
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
