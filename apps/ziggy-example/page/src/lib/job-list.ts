//
// Keeps the running list of jobs from the job-progress messages tasks send, the way the real frontend does: a task
// that reports a job id counts towards that job, and the job is dropped when the last task carrying its id completes.
//

//
// A job's identity, as a task reports it in a job-progress message.
//
export interface IJobTag {
    // The job's id. Tasks sharing an id are one job.
    id: string;

    // The job's name.
    name: string;

    // The source whose cancellation cancels the job, when it has one.
    cancelSource?: string;
}

//
// A job-progress message, with the fields of IJobProgressMessage.
//
export interface IJobProgressMessage {
    // Always "job-progress".
    type: "job-progress";

    // The job the message is about.
    job: IJobTag;

    // When the job started, in milliseconds since the Unix epoch.
    startedAt: number;

    // What the job is doing now.
    progressMessage?: string;
}

//
// A job as the page lists it.
//
export interface IJob {
    // The job's id.
    id: string;

    // The job's name.
    name: string;

    // The source whose cancellation cancels the job, when it has one.
    cancelSource?: string;

    // When the job started.
    startedAt: number;

    // The latest thing the job said it was doing.
    progressMessage?: string;
}

//
// The list of jobs, and which job each running task has reported.
//
export interface IJobList {
    // The jobs, in the order they first reported.
    jobs: IJob[];

    // The job id each task has reported, by task id.
    taskJobIds: { [taskId: string]: string };
}

//
// A list with no jobs.
//
export function emptyJobList(): IJobList {
    return {
        jobs: [],
        taskJobIds: {},
    };
}

//
// Applies a job-progress message sent by a task. A first message from a job adds it, and a later one updates what it
// says it is doing.
//
export function applyJobProgress(list: IJobList, taskId: string, message: IJobProgressMessage): IJobList {
    const taskJobIds = { ...list.taskJobIds, [taskId]: message.job.id };
    const existing = list.jobs.find(job => job.id === message.job.id);
    if (!existing) {
        return {
            jobs: [
                ...list.jobs,
                {
                    id: message.job.id,
                    name: message.job.name,
                    cancelSource: message.job.cancelSource,
                    startedAt: message.startedAt,
                    progressMessage: message.progressMessage,
                },
            ],
            taskJobIds,
        };
    }
    return {
        jobs: list.jobs.map(job => job.id === message.job.id ? { ...job, progressMessage: message.progressMessage } : job),
        taskJobIds,
    };
}

//
// Applies the completion of a task. The job the task reported is dropped when no other task still carries its id.
//
export function applyTaskCompleted(list: IJobList, taskId: string): IJobList {
    const jobId = list.taskJobIds[taskId];
    if (jobId === undefined) {
        return list;
    }
    const taskJobIds = { ...list.taskJobIds };
    delete taskJobIds[taskId];
    const stillCarried = Object.values(taskJobIds).includes(jobId);
    return {
        jobs: stillCarried ? list.jobs : list.jobs.filter(job => job.id !== jobId),
        taskJobIds,
    };
}
