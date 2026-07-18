/**
 * @jest-environment jsdom
 */

import React from "react";
import { act, render, screen } from "@testing-library/react";
import {
    applyCompleteJob,
    applyRegisterJob,
    applyUpdateJob,
    computeAggregateProgress,
    JobsContextProvider,
    useJobs,
    type IJob,
    type IJobsContext,
} from "../../context/jobs-context";
import { PlatformContextProvider, type IPlatformContext } from "../../context/platform-context";

//
// Builds a minimal job for tests.
//
function makeJob(overrides: Partial<IJob> & Pick<IJob, "id">): IJob {
    return {
        id: overrides.id,
        name: overrides.name ?? `Job ${overrides.id}`,
        sourceTag: overrides.sourceTag ?? overrides.id,
        progress: overrides.progress,
        progressMessage: overrides.progressMessage,
        cancellable: overrides.cancellable ?? true,
        startedAt: overrides.startedAt ?? 1000,
    };
}

describe("jobs-context helpers", () => {
    test("applyRegisterJob adds a job and replaces an existing id in place", () => {
        const first = makeJob({ id: "a", startedAt: 10, name: "First" });
        const second = makeJob({ id: "b", startedAt: 20, name: "Second" });
        const replaced = makeJob({ id: "a", startedAt: 15, name: "Replaced" });

        const withTwo = applyRegisterJob(applyRegisterJob([], first), second);
        expect(withTwo.map(job => job.id)).toEqual(["a", "b"]);

        const afterReplace = applyRegisterJob(withTwo, replaced);
        expect(afterReplace).toHaveLength(2);
        expect(afterReplace.find(job => job.id === "a")?.name).toBe("Replaced");
        expect(afterReplace.map(job => job.id)).toEqual(["a", "b"]);
    });

    test("applyUpdateJob merges fields and is a no-op for unknown ids", () => {
        const jobs = [makeJob({ id: "a", progress: 0.2, progressMessage: "start" })];
        const updated = applyUpdateJob(jobs, "a", { progress: 0.5, progressMessage: "halfway" });
        expect(updated[0].progress).toBe(0.5);
        expect(updated[0].progressMessage).toBe("halfway");
        expect(updated[0].id).toBe("a");

        const unchanged = applyUpdateJob(jobs, "missing", { progress: 1 });
        expect(unchanged).toBe(jobs);
    });

    test("applyCompleteJob removes by id", () => {
        const jobs = [
            makeJob({ id: "a", startedAt: 1 }),
            makeJob({ id: "b", startedAt: 2 }),
        ];
        expect(applyCompleteJob(jobs, "a").map(job => job.id)).toEqual(["b"]);
        expect(applyCompleteJob(jobs, "missing")).toEqual(jobs);
    });

    test("computeAggregateProgress averages numeric progress and ignores indeterminate jobs", () => {
        expect(computeAggregateProgress([])).toBeUndefined();
        expect(computeAggregateProgress([
            makeJob({ id: "a", progress: undefined }),
        ])).toBeUndefined();
        expect(computeAggregateProgress([
            makeJob({ id: "a", progress: 0.2 }),
            makeJob({ id: "b", progress: undefined }),
            makeJob({ id: "c", progress: 0.6 }),
        ])).toBeCloseTo(0.4);
    });
});

//
// Test consumer that exposes the jobs context for assertions.
//
function JobsProbe({ onReady }: { onReady: (value: IJobsContext) => void }) {
    const jobsContext = useJobs();
    React.useEffect(() => {
        onReady(jobsContext);
    }, [jobsContext, onReady]);
    return (
        <div>
            <span data-testid="job-count">{jobsContext.jobs.length}</span>
            {jobsContext.jobs.map(job => (
                <div key={job.id} data-testid={`job-${job.id}`}>{job.name}</div>
            ))}
        </div>
    );
}

describe("JobsContextProvider", () => {
    test("registerJob, updateJob, completeJob, and cancelJob behave as specified", async () => {
        const cancelTasks = jest.fn().mockResolvedValue(undefined);
        const platform = {
            cancelTasks,
        } as unknown as IPlatformContext;

        let latest: IJobsContext | undefined;
        render(
            <PlatformContextProvider value={platform}>
                <JobsContextProvider>
                    <JobsProbe onReady={value => { latest = value; }} />
                </JobsContextProvider>
            </PlatformContextProvider>
        );

        expect(latest).toBeDefined();

        await act(async () => {
            latest!.registerJob(makeJob({ id: "import-1", sourceTag: "session-1", name: "Importing" }));
        });
        expect(screen.getByTestId("job-count").textContent).toBe("1");
        expect(screen.getByTestId("job-import-1").textContent).toBe("Importing");

        await act(async () => {
            latest!.registerJob(makeJob({ id: "import-1", sourceTag: "session-1", name: "Importing 3 files" }));
        });
        expect(screen.getByTestId("job-count").textContent).toBe("1");
        expect(screen.getByTestId("job-import-1").textContent).toBe("Importing 3 files");

        await act(async () => {
            latest!.updateJob("import-1", { progress: 0.5, progressMessage: "1 of 2 files" });
            latest!.updateJob("missing", { progress: 1 });
        });
        expect(latest!.jobs[0].progress).toBe(0.5);
        expect(latest!.jobs[0].progressMessage).toBe("1 of 2 files");

        await act(async () => {
            latest!.completeJob("import-1");
        });
        expect(screen.getByTestId("job-count").textContent).toBe("0");

        await act(async () => {
            latest!.registerJob(makeJob({ id: "load-1", sourceTag: "/db/path", name: "Loading" }));
            latest!.cancelJob("load-1");
        });
        expect(cancelTasks).toHaveBeenCalledWith("/db/path");
        expect(screen.getByTestId("job-count").textContent).toBe("0");
    });

    test("useJobs throws when no provider is present", () => {
        const consoleError = jest.spyOn(console, "error").mockImplementation(() => undefined);
        expect(() => {
            render(<JobsProbe onReady={() => undefined} />);
        }).toThrow("JobsContext is not set");
        consoleError.mockRestore();
    });
});
