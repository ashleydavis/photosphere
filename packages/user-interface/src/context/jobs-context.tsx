import React, { ReactNode, createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import type { IJobProgressMessage } from "task-queue";
import { log } from "utils";
import { usePlatform } from "./platform-context";
import { applyJobProgress, applyTaskCompleted, describeJobListChanges, type IJob } from "../lib/jobs";

//
// The background work running right now, and how to stop it.
//
// Built entirely from the two task streams every platform already delivers: the messages running
// tasks send, and the completions that follow them. Nothing here asks the backend what is running,
// because nothing in the backend knows: a job is a name a task was queued with, and this is the only
// place that collects them into a list.
//
export interface IJobsContext {
    //
    // What is running, oldest first.
    //
    jobs: IJob[];

    //
    // Stops the job with the given id by cancelling its tasks. Does nothing for a job that carries
    // no cancel source, which is how a background sync says it is not the interface's to stop.
    //
    // The row is not removed here. Cancelling makes the task fail, the failure arrives as a task
    // completion, and that is what takes the row away, so the row goes when the work does rather
    // than when the button was pressed.
    //
    cancelJob: (id: string) => void;

    //
    // Stops every job that can be stopped. Jobs carrying no cancel source are left alone, so a
    // background sync carries on rather than being silently killed by a button that did not name it.
    //
    cancelAllJobs: () => void;

    //
    // True while at least one running job can be cancelled, so the interface knows whether a
    // "Cancel all" button would do anything.
    //
    canCancelAny: boolean;
}

//
// Exported so a story can supply a fixed job list directly. Jobs only exist while work is running,
// so the states worth looking at (several at once, a job that cannot be cancelled) cannot be
// reached by driving the real app at all reliably.
//
export const JobsContext = createContext<IJobsContext | undefined>(undefined);

//
// Props for the jobs context provider.
//
export interface IJobsContextProviderProps {
    //
    // The subtree that can read the job list.
    //
    children: ReactNode | ReactNode[];
}

//
// Collects the jobs running in the background and provides them to its subtree.
//
export function JobsContextProvider({ children }: IJobsContextProviderProps) {
    const platform = usePlatform();

    const [jobs, setJobs] = useState<IJob[]>([]);

    //
    // A synchronous copy of the list, so cancelJob can look a job up without depending on the list
    // and being rebuilt every time any job's progress moves.
    //
    const jobsRef = useRef<IJob[]>([]);

    useEffect(() => {
        jobsRef.current = jobs;
    }, [jobs]);

    //
    // The name of every job recorded as started but not yet as finished, so each is logged once.
    //
    const loggedJobNames = useRef<Map<string, string>>(new Map());

    //
    // Record what started and what finished in the app log. On a phone there is no console to watch
    // and the work carries on with the screen off, so the log is the only account of what ran.
    //
    useEffect(() => {
        const changes = describeJobListChanges(loggedJobNames.current, jobs);
        loggedJobNames.current = changes.names;

        for (const name of changes.started) {
            log.event(`Background job started: ${name}`);
        }
        for (const name of changes.finished) {
            log.event(`Background job finished: ${name}`);
        }
    }, [jobs]);

    //
    // Collect job progress from running tasks, and drop a job when its last task finishes.
    //
    useEffect(() => {
        const unsubscribeMessage = platform.onTaskMessage((taskId, message) => {
            if (message.type !== "job-progress") {
                return;
            }
            setJobs(current => applyJobProgress(current, taskId, message as unknown as IJobProgressMessage));
        });

        const unsubscribeComplete = platform.onTaskComplete(taskId => {
            setJobs(current => applyTaskCompleted(current, taskId));
        });

        return () => {
            unsubscribeMessage();
            unsubscribeComplete();
        };
    }, [platform]);

    const cancelJob = useCallback((id: string): void => {
        const job = jobsRef.current.find(candidate => candidate.id === id);
        if (!job || !job.cancelSource) {
            return;
        }

        platform.cancelTasks(job.cancelSource)
            .catch(error => {
                // The row deliberately stays. A cancel that did not get through means the work is
                // still running, and a row that vanished would say the opposite.
                log.exception(`Failed to cancel job "${job.name}"`, error as Error);
            });
    }, [platform]);

    const cancelAllJobs = useCallback((): void => {
        // Each job is cancelled by its own source rather than by one sweeping call, because there is
        // no such thing as "cancel everything" at the task level: cancelTasks takes a source, and the
        // sources belong to the jobs.
        for (const job of jobsRef.current) {
            if (!job.cancelSource) {
                continue;
            }

            platform.cancelTasks(job.cancelSource)
                .catch(error => {
                    log.exception(`Failed to cancel job "${job.name}"`, error as Error);
                });
        }
    }, [platform]);

    const contextValue: IJobsContext = {
        jobs,
        cancelJob,
        cancelAllJobs,
        canCancelAny: jobs.some(job => job.cancelSource !== undefined),
    };

    return (
        <JobsContext.Provider value={contextValue}>
            {children}
        </JobsContext.Provider>
    );
}

//
// Hook to access the job list.
//
export function useJobs(): IJobsContext {
    const context = useContext(JobsContext);
    if (!context) {
        throw new Error(`JobsContext is not set! Add JobsContextProvider to the component tree.`);
    }
    return context;
}
