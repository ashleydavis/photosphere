//
// The job list the interface shows: what is running in the background, how long it has been going,
// and what it is doing.
//
// Jobs live only here. Nothing in the backend or in a worker keeps job state or decides when a job
// is over: a task carries a job tag in its input data, its handler reports progress against that
// tag, and this builds the list from those reports and from the task completions that follow them.
//

import type { IJobProgressMessage } from "task-queue";

//
// One row in the job list.
//
export interface IJob {
    //
    // The job tag's id. Every task of this job reports it, and it is the row's React key.
    //
    id: string;

    //
    // What the row is called, for example "Importing photos".
    //
    name: string;

    //
    // The task source the Cancel button passes to cancelTasks(). Undefined when the job cannot be
    // cancelled from here, which is how the row knows not to render a Cancel button.
    //
    cancelSource: string | undefined;

    //
    // When the work started, in milliseconds since the epoch, as reported by the handler doing it.
    // The elapsed time shown counts from here, so a job that was already running when the app came
    // back to the foreground reports its real age.
    //
    startedAt: number;

    //
    // What the job is doing right now, or undefined when it has not said.
    //
    progressMessage: string | undefined;

    //
    // The tasks seen reporting this job that have not completed yet. The row goes when this empties,
    // which is what makes a sync pass made of several steps one row rather than one row per step.
    //
    taskIds: string[];
}

//
// What the navbar indicator renders.
//
export interface IJobsIndicatorView {
    //
    // The line of text beside the navbar spinner: how many jobs are running.
    //
    label: string;
}

//
// Applies one job-progress report to the list, adding the job the first time its id is seen and
// updating it after that.
//
// The earliest startedAt seen for a job wins, so a sync pass made of several steps reports the age
// of the pass rather than of whichever step is running now.
//
export function applyJobProgress(jobs: IJob[], taskId: string, message: IJobProgressMessage): IJob[] {
    const existing = jobs.find(job => job.id === message.job.id);
    if (!existing) {
        const added: IJob = {
            id: message.job.id,
            name: message.job.name,
            cancelSource: message.job.cancelSource,
            startedAt: message.startedAt,
            progressMessage: message.progressMessage,
            taskIds: [taskId],
        };
        return sortJobs(jobs.concat(added));
    }

    const updated: IJob = {
        ...existing,
        name: message.job.name,
        cancelSource: message.job.cancelSource,
        startedAt: Math.min(existing.startedAt, message.startedAt),
        progressMessage: message.progressMessage,
        taskIds: existing.taskIds.includes(taskId)
            ? existing.taskIds
            : existing.taskIds.concat(taskId),
    };

    // A report that says nothing new hands back the list it was given, so React bails out instead of
    // repainting. Workers report on a timer as well as on progress, so an import sitting on the same
    // counts sends the same report over and over.
    if (isSameJob(existing, updated)) {
        return jobs;
    }

    return sortJobs(jobs.map(job => job.id === updated.id ? updated : job));
}

//
// Drops a completed task from whichever job was counting it, removing the job when that was its last
// one.
//
// Returns the list it was given when no job holds the task, so the many completions that are not
// jobs at all (every hash-file, every upload-asset) cost nothing.
//
export function applyTaskCompleted(jobs: IJob[], taskId: string): IJob[] {
    const owner = jobs.find(job => job.taskIds.includes(taskId));
    if (!owner) {
        return jobs;
    }

    const remaining = owner.taskIds.filter(id => id !== taskId);
    if (remaining.length === 0) {
        return jobs.filter(job => job.id !== owner.id);
    }

    return jobs.map(job => job.id === owner.id
        ? {
            ...job,
            taskIds: remaining,
        }
        : job);
}

//
// What the navbar indicator should show, or undefined when nothing is running and it renders
// nothing at all.
//
// A count rather than the job's name, however much room there looks to be.
//
// The navbar is the most crowded row in the app and it is the same component on a phone, where
// "Replicating to my-holiday-backup" has nowhere to go: it was hidden entirely below the small
// breakpoint, leaving a spinner that said nothing, and on a narrow desktop window it wrapped onto
// two lines and collided with the navigation links. The names are one tap away in the sidebar, which
// has room for them.
//
export function describeJobsIndicator(jobs: IJob[]): IJobsIndicatorView | undefined {
    if (jobs.length === 0) {
        return undefined;
    }

    return {
        label: jobs.length === 1
            ? "1 job"
            : `${jobs.length} jobs`,
    };
}

//
// Which jobs have appeared and which have gone since the list was last looked at.
//
export interface IJobListChanges {
    //
    // The names of the jobs that have started, in the order they appear in the list.
    //
    started: string[];

    //
    // The names of the jobs that have finished.
    //
    finished: string[];

    //
    // The name of every job now running, keyed by its id. Pass this back in next time.
    //
    names: Map<string, string>;
}

//
// Works out what has started and what has finished, so both can be recorded in the app log.
//
// The log is how this app is diagnosed on every platform, and a phone is the case that needs it:
// there is no console to watch and the work carries on while the screen is off, so what ran and how
// long it took can only be read afterwards.
//
export function describeJobListChanges(previousNames: Map<string, string>, jobs: IJob[]): IJobListChanges {
    const names = new Map<string, string>();
    const started: string[] = [];

    for (const job of jobs) {
        names.set(job.id, job.name);
        if (!previousNames.has(job.id)) {
            started.push(job.name);
        }
    }

    const finished: string[] = [];
    for (const [id, name] of previousNames) {
        if (!names.has(id)) {
            finished.push(name);
        }
    }

    return {
        started,
        finished,
        names,
    };
}

//
// How long a job has been running, for the row beside its name.
//
// Coarse on purpose: this is glanced at rather than read, and a figure that changed in its last
// digit every second would pull the eye to the one part of the row that means the least.
//
export function formatElapsed(elapsedMs: number): string {
    const totalSeconds = Math.max(0, Math.floor(elapsedMs / 1000));
    if (totalSeconds < 60) {
        return `${totalSeconds}s`;
    }

    const totalMinutes = Math.floor(totalSeconds / 60);
    if (totalMinutes < 60) {
        return `${totalMinutes}m ${totalSeconds % 60}s`;
    }

    const totalHours = Math.floor(totalMinutes / 60);
    return `${totalHours}h ${totalMinutes % 60}m`;
}

//
// Whether two versions of a job would render identically, so an update that changes nothing can be
// dropped rather than repainting the row.
//
function isSameJob(first: IJob, second: IJob): boolean {
    return first.name === second.name
        && first.cancelSource === second.cancelSource
        && first.startedAt === second.startedAt
        && first.progressMessage === second.progressMessage
        && first.taskIds === second.taskIds;
}

//
// Oldest job first, so a row does not jump about as the jobs around it come and go.
//
function sortJobs(jobs: IJob[]): IJob[] {
    return jobs.slice().sort((first, second) => first.startedAt - second.startedAt);
}
