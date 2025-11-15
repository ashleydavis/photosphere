//
// Interface for worker pools that can be used by MediaFileDatabase
// This allows the API package to use workers without depending on a specific implementation
//

//
// Task types for workers
//
export interface IHashTask {
    type: 'hash';
    filePath: string;
}

export interface IValidateTask {
    type: 'validate';
    filePath: string;
    contentType: string;
    tempDir: string;
}

export type IWorkerTask = IHashTask | IValidateTask;

//
// Result types for workers
//
export interface IHashResult {
    hash: Buffer;
}

export interface IValidateResult {
    valid: boolean;
    error?: string;
}

export type IWorkerResult<T extends IWorkerTask> =
    T extends IHashTask ? IHashResult :
    T extends IValidateTask ? IValidateResult :
    never;

//
// Worker pool interface
//
export interface IWorkerPool {
    //
    // Executes a single task
    //
    execute<T extends IWorkerTask>(task: T): Promise<IWorkerResult<T>>;

    //
    // Executes multiple tasks in parallel
    //
    executeBatch<T extends IWorkerTask>(tasks: T[]): Promise<Array<IWorkerResult<T> | Error>>;

    //
    // Terminates all workers
    //
    terminate(): Promise<void>;
}

