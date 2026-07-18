import React from "react";
import Box from "@mui/joy/Box";
import CircularProgress from "@mui/joy/CircularProgress";
import Typography from "@mui/joy/Typography";
import { computeAggregateProgress, useJobs } from "../context/jobs-context";

//
// Custom DOM event dispatched when the navbar jobs indicator is clicked.
// The layout listens for this to open the right sidebar.
//
export const SHOW_JOBS_EVENT = "photosphere:show-jobs";

//
// Compact navbar indicator for running background jobs.
// Shows the single job name, or "N background jobs running" when multiple.
// Clicking dispatches SHOW_JOBS_EVENT so the layout can open the right sidebar.
//
export function NavbarJobsIndicator() {
    const { jobs } = useJobs();

    if (jobs.length === 0) {
        return null;
    }

    const aggregateProgress = computeAggregateProgress(jobs);
    const isDeterminate = aggregateProgress !== undefined;
    const progressPercent = isDeterminate ? Math.round(aggregateProgress * 100) : undefined;

    let label: string;
    if (jobs.length === 1) {
        label = jobs[0].name;
    }
    else {
        label = `${jobs.length} background jobs running`;
    }

    //
    // Asks the layout to open the right sidebar jobs list.
    //
    function handleClick(): void {
        window.dispatchEvent(new CustomEvent(SHOW_JOBS_EVENT));
    }

    return (
        <Box
            data-id="navbar-jobs-indicator"
            onClick={handleClick}
            sx={{
                display: "flex",
                flexDirection: "row",
                alignItems: "center",
                gap: 1,
                mr: 2,
                cursor: "pointer",
            }}
            title="Show background jobs"
        >
            <CircularProgress
                size="sm"
                determinate={isDeterminate}
                value={isDeterminate ? aggregateProgress * 100 : undefined}
            />
            <Typography level="body-sm">
                {label}
                {jobs.length === 1 && progressPercent !== undefined && (
                    <Typography component="span" level="body-xs" sx={{ ml: 0.5, color: "neutral.500" }}>
                        {progressPercent}%
                    </Typography>
                )}
            </Typography>
        </Box>
    );
}
