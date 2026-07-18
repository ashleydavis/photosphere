/**
 * @jest-environment jsdom
 */

import React from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { NavbarJobsIndicator, SHOW_JOBS_EVENT } from "../../components/navbar-jobs-indicator";
import { JobsContext, type IJob, type IJobsContext } from "../../context/jobs-context";

//
// Builds a stub jobs context value for rendering the indicator.
//
function stubJobs(jobs: IJob[]): IJobsContext {
    return {
        jobs,
        registerJob: jest.fn(),
        updateJob: jest.fn(),
        completeJob: jest.fn(),
        cancelJob: jest.fn(),
    };
}

//
// Builds a minimal job for indicator tests.
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

describe("NavbarJobsIndicator", () => {
    test("renders nothing for 0 jobs", () => {
        const { container } = render(
            <JobsContext.Provider value={stubJobs([])}>
                <NavbarJobsIndicator />
            </JobsContext.Provider>
        );
        expect(container.firstChild).toBeNull();
    });

    test("renders job name for 1 job and percentage when progress is set", () => {
        render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "Importing assets", progress: 0.5 }),
            ])}>
                <NavbarJobsIndicator />
            </JobsContext.Provider>
        );
        expect(screen.getByText("Importing assets")).toBeTruthy();
        expect(screen.getByText("50%")).toBeTruthy();
        expect(document.querySelector('[data-id="navbar-jobs-indicator"]')).toBeTruthy();
    });

    test("renders N background jobs running for multiple jobs", () => {
        render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "One", progress: 0.2 }),
                makeJob({ id: "b", name: "Two", progress: 0.6 }),
                makeJob({ id: "c", name: "Three" }),
            ])}>
                <NavbarJobsIndicator />
            </JobsContext.Provider>
        );
        expect(screen.getByText("3 background jobs running")).toBeTruthy();
    });

    test("dispatches photosphere:show-jobs when clicked", () => {
        const handler = jest.fn();
        window.addEventListener(SHOW_JOBS_EVENT, handler);
        render(
            <JobsContext.Provider value={stubJobs([
                makeJob({ id: "a", name: "Importing assets" }),
            ])}>
                <NavbarJobsIndicator />
            </JobsContext.Provider>
        );
        fireEvent.click(document.querySelector('[data-id="navbar-jobs-indicator"]') as Element);
        expect(handler).toHaveBeenCalledTimes(1);
        window.removeEventListener(SHOW_JOBS_EVENT, handler);
    });
});
