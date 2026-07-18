/**
 * @jest-environment jsdom
 */

import React from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { SidebarJobsList } from "../../components/sidebar-jobs-list";
import { JobsContext, type IJob, type IJobsContext } from "../../context/jobs-context";

//
// Builds a stub jobs context value for rendering the sidebar list.
//
function stubJobs(jobs: IJob[], cancelJob: IJobsContext["cancelJob"] = jest.fn()): IJobsContext {
    return {
        jobs,
        registerJob: jest.fn(),
        updateJob: jest.fn(),
        completeJob: jest.fn(),
        cancelJob,
    };
}

//
// Builds a minimal job for sidebar tests.
//
function makeJob(overrides: Partial<IJob> & Pick<IJob, "id" | "name">): IJob {
    return {
        id: overrides.id,
        name: overrides.name,
        sourceTag: overrides.sourceTag ?? overrides.id,
        progress: overrides.progress,
        progressMessage: overrides.progressMessage,
        cancellable: overrides.cancellable ?? true,
        startedAt: overrides.startedAt ?? 1,
    };
}

describe("SidebarJobsList", () => {
    test("empty state renders nothing", () => {
        const { container } = render(
            <JobsContext.Provider value={stubJobs([])}>
                <SidebarJobsList />
            </JobsContext.Provider>
        );
        expect(container.firstChild).toBeNull();
    });

    test("renders one row per job with progress message", () => {
        render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "Importing", progressMessage: "1 of 2 files", progress: 0.5 }),
                makeJob({ id: "b", name: "Syncing", cancellable: false }),
            ])}>
                <SidebarJobsList />
            </JobsContext.Provider>
        );

        expect(document.querySelector('[data-id="sidebar-jobs-list"]')).toBeTruthy();
        expect(document.querySelector('[data-id="sidebar-job-row-a"]')).toBeTruthy();
        expect(document.querySelector('[data-id="sidebar-job-row-b"]')).toBeTruthy();
        expect(screen.getByText("Importing")).toBeTruthy();
        expect(screen.getByText("1 of 2 files")).toBeTruthy();
        expect(screen.getByText("Syncing")).toBeTruthy();
        expect(screen.getByText("Background jobs")).toBeTruthy();
    });

    test("cancel icon button calls cancelJob and is omitted when not cancellable", () => {
        const cancelJob = jest.fn();
        render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "Importing", cancellable: true }),
                makeJob({ id: "b", name: "Syncing", cancellable: false }),
            ], cancelJob)}>
                <SidebarJobsList />
            </JobsContext.Provider>
        );

        expect(document.querySelector('[data-id="sidebar-job-cancel-a"]')).toBeTruthy();
        expect(document.querySelector('[data-id="sidebar-job-cancel-b"]')).toBeNull();

        fireEvent.click(document.querySelector('[data-id="sidebar-job-cancel-a"]') as Element);
        expect(cancelJob).toHaveBeenCalledWith("a");
    });

    test("uses determinate LinearProgress when progress is defined", () => {
        const { container } = render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "Importing", progress: 0.25 }),
                makeJob({ id: "b", name: "Loading" }),
            ])}>
                <SidebarJobsList />
            </JobsContext.Provider>
        );

        const progressBars = container.querySelectorAll('[role="progressbar"]');
        expect(progressBars.length).toBe(2);
        expect(progressBars[0].getAttribute("aria-valuenow")).toBe("25");
        expect(progressBars[1].getAttribute("aria-valuenow")).toBeNull();
    });
});
