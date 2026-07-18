import React from "react";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import LinearProgress from "@mui/joy/LinearProgress";
import IconButton from "@mui/joy/IconButton";
import Divider from "@mui/joy/Divider";
import { useJobs } from "../context/jobs-context";

//
// Right-sidebar section listing active background jobs with progress and cancel.
// Renders nothing when there are no jobs.
//
export function SidebarJobsList() {
    const { jobs, cancelJob } = useJobs();

    if (jobs.length === 0) {
        return null;
    }

    return (
        <>
            <Box data-id="sidebar-jobs-list" sx={{ px: "15px", py: 1 }}>
                <Typography level="title-sm" sx={{ mb: 1 }}>
                    Background jobs
                </Typography>
                {jobs.map(job => (
                    <Box
                        key={job.id}
                        data-id={`sidebar-job-row-${job.id}`}
                        sx={{ mb: 1.5 }}
                    >
                        <Box sx={{ display: "flex", alignItems: "flex-start", gap: 1 }}>
                            <Box sx={{ flexGrow: 1, minWidth: 0 }}>
                                <Typography level="body-sm">{job.name}</Typography>
                                {job.progressMessage && (
                                    <Typography level="body-xs" sx={{ color: "neutral.500" }}>
                                        {job.progressMessage}
                                    </Typography>
                                )}
                            </Box>
                            {job.cancellable && (
                                <IconButton
                                    data-id={`sidebar-job-cancel-${job.id}`}
                                    size="sm"
                                    variant="plain"
                                    color="danger"
                                    aria-label="Cancel job"
                                    title="Cancel"
                                    onClick={() => cancelJob(job.id)}
                                >
                                    <i className="fa-solid fa-xmark"></i>
                                </IconButton>
                            )}
                        </Box>
                        {job.progress !== undefined
                            ? (
                                <LinearProgress
                                    determinate
                                    value={job.progress * 100}
                                    sx={{ mt: 0.5 }}
                                />
                            )
                            : (
                                <LinearProgress sx={{ mt: 0.5 }} />
                            )
                        }
                    </Box>
                ))}
            </Box>
            <Divider />
        </>
    );
}
