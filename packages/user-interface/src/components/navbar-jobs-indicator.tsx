import React from "react";
import Chip from "@mui/material/Chip";
import CircularProgress from "@mui/material/CircularProgress";
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
                    title="Show background jobs"
                    onClick={() => window.dispatchEvent(new CustomEvent("photosphere:show-jobs"))}
                    //
                    // Always spinning, never filling. This says "something is running", and a ring
                    // creeping round once over a minute reads as a stuck app rather than a busy one.
                    //
                    icon={<CircularProgress size="var(--icon-sm)" color="inherit" />}
                    //
                    // The count is desktop only. A mobile's navbar has no room to spare, and the
                    // spinner alone still says work is happening; how much and what it is are one
                    // tap away in the dialog.
                    //
                    label={isMobile ? undefined : indicator.label}
                    sx={[
                        {
                            whiteSpace: 'nowrap',
                            color: 'var(--color-navbar-chip-text)',
                            backgroundColor: 'var(--color-navbar-chip-bg)',
                            borderColor: 'var(--color-navbar-chip-border)',
                            '& .MuiChip-icon': {
                                color: 'var(--color-accent)',
                                marginLeft: 'var(--space-3)',
                                marginRight: 0,
                            },
                            '&:hover': {
                                backgroundColor: 'var(--color-hover)',
                            },
                            '&.Mui-focusVisible': {
                                backgroundColor: 'var(--color-hover)',
                                outline: 'var(--focus-ring-width) solid var(--color-focus)',
                                outlineOffset: 'var(--focus-ring-offset)',
                            },
                        },
                        //
                        // On a mobile the chip is a square the size of the navbar's other icon
                        // buttons, holding the spinner alone, as the style guide's mobile navbar
                        // draws the background jobs.
                        //
                        isMobile
                            ? {
                                width: 'var(--button-height-lg)',
                                height: 'var(--button-height-lg)',
                                justifyContent: 'center',
                                borderColor: 'var(--color-icon-button-border)',
                                borderRadius: 'var(--radius-icon-button)',
                                backgroundColor: 'var(--color-icon-button-fill)',
                                '& .MuiChip-icon': {
                                    margin: 0,
                                },
                                '& .MuiChip-label': {
                                    display: 'none',
                                },
                            }
                            : {},
                    ]}
                    />
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
