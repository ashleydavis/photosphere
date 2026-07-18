import React, { createContext, useCallback, useContext, useState } from "react";
import { usePlatform } from "./platform-context";

//
// Adding a new background job: call `registerJob()` when work starts, `updateJob()` from any
// progress callback, and `completeJob()` from both success and failure paths. Set `sourceTag`
// to whatever string the worker handler tagged its tasks with so `cancelJob()` can route
// through `platform.cancelTasks()`.
//

//
// A single user-visible background activity managed by the Job Manager.
//
export interface IJob {
    //
    // Stable job id, used as React key and lookup key. Reuse the existing tag where possible:
    // sessionId for import, the database path for load-assets / sync, the source path for replicate.
    //
    id: string;

    //
    // Human-readable label, e.g. "Importing 124 photos", "Loading database 'Family'".
    //
    name: string;

    //
    // Value passed to `platform.cancelTasks(sourceTag)` to terminate this job's worker tasks.
    // Often equal to `id`; kept separate so jobs that don't map 1:1 to a task source can still cancel.
    //
    sourceTag: string;

    //
    // Fractional progress in 0..1. Undefined means indeterminate (show a spinner instead of a bar).
    //
    progress: number | undefined;

    //
    // Short human-readable detail (e.g. "Copying display.jpg", "123 of 500").
    //
    progressMessage: string | undefined;

    //
    // Whether the Cancel button is rendered for this job.
    //
    cancellable: boolean;

    //
    // Date.now() at registration; used to sort the sidebar list.
    //
    startedAt: number;
}

//
// Patch type for updating a registered job (id is immutable).
//
export type IJobUpdate = Partial<Omit<IJob, "id">>;

//
// Job Manager context value provided to consumers.
//
export interface IJobsContext {
    //
    // Current jobs ordered by startedAt.
    //
    jobs: IJob[];

    //
    // Adds or replaces a job (idempotent on id).
    //
    registerJob: (job: IJob) => void;

    //
    // Merges a partial update into a registered job; no-op if the id is unknown.
    //
    updateJob: (id: string, patch: IJobUpdate) => void;

    //
    // Removes the job from the list.
    //
    completeJob: (id: string) => void;

    //
    // Calls platform.cancelTasks(job.sourceTag) and immediately removes the job.
    //
    cancelJob: (id: string) => void;
}

//
// React context carrying the Job Manager state.
// Exported so stories and tests can supply a custom value directly.
//
export const JobsContext = createContext<IJobsContext | undefined>(undefined);

export interface IJobsContextProviderProps {
    //
    // Child components that can access the jobs context.
    //
    children: React.ReactNode | React.ReactNode[];
}

//
// Sorts jobs by startedAt ascending (oldest first).
//
export function sortJobsByStartedAt(jobs: IJob[]): IJob[] {
    return [...jobs].sort((jobA, jobB) => jobA.startedAt - jobB.startedAt);
}

//
// Applies register semantics: add or replace by id, then sort by startedAt.
//
export function applyRegisterJob(jobs: IJob[], job: IJob): IJob[] {
    const withoutExisting = jobs.filter(existing => existing.id !== job.id);
    return sortJobsByStartedAt([...withoutExisting, job]);
}

//
// Applies update semantics: merge patch into the matching job; no-op when id is unknown.
//
export function applyUpdateJob(jobs: IJob[], id: string, patch: IJobUpdate): IJob[] {
    let found = false;
    const updated = jobs.map(job => {
        if (job.id !== id) {
            return job;
        }
        found = true;
        return { ...job, ...patch, id: job.id };
    });
    if (!found) {
        return jobs;
    }
    return sortJobsByStartedAt(updated);
}

//
// Removes a job by id.
//
export function applyCompleteJob(jobs: IJob[], id: string): IJob[] {
    return jobs.filter(job => job.id !== id);
}

//
// Computes mean progress across jobs that have a numeric progress value.
// Returns undefined when no jobs contribute a numeric progress.
//
export function computeAggregateProgress(jobs: IJob[]): number | undefined {
    const withProgress = jobs.filter(job => job.progress !== undefined);
    if (withProgress.length === 0) {
        return undefined;
    }
    const sum = withProgress.reduce((total, job) => total + (job.progress as number), 0);
    return sum / withProgress.length;
}

//
// Provider component for the Job Manager.
// Holds registered jobs and routes cancellation through platform.cancelTasks.
//
export function JobsContextProvider({ children }: IJobsContextProviderProps) {
    const platform = usePlatform();
    const [jobs, setJobs] = useState<IJob[]>([]);

    const registerJob = useCallback((job: IJob): void => {
        setJobs(prev => applyRegisterJob(prev, job));
    }, []);

    const updateJob = useCallback((id: string, patch: IJobUpdate): void => {
        setJobs(prev => applyUpdateJob(prev, id, patch));
    }, []);

    const completeJob = useCallback((id: string): void => {
        setJobs(prev => applyCompleteJob(prev, id));
    }, []);

    const cancelJob = useCallback((id: string): void => {
        setJobs(prev => {
            const job = prev.find(candidate => candidate.id === id);
            if (job) {
                // Fire-and-forget: cancelTasks is async but cancelJob is sync per the API.
                void platform.cancelTasks(job.sourceTag);
            }
            return applyCompleteJob(prev, id);
        });
    }, [platform]);

    const contextValue: IJobsContext = {
        jobs,
        registerJob,
        updateJob,
        completeJob,
        cancelJob,
    };

    return (
        <JobsContext.Provider value={contextValue}>
            {children}
        </JobsContext.Provider>
    );
}

//
// Hook to access the Job Manager context.
//
export function useJobs(): IJobsContext {
    const context = useContext(JobsContext);
    if (!context) {
        throw new Error(`JobsContext is not set! Add JobsContextProvider to the component tree.`);
    }
    return context;
}
