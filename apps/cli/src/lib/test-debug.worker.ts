//
// Test debug worker handler - handles test-sleep tasks for debugging
//

import { sleep } from "utils";
import type { IWorkerContext } from "task-queue";

export interface ITestSleepData {
    sleepMs: number;
    taskNumber: number;
}

export interface ITestSleepResult {
    slept: number;
}

//
// Handler for test-sleep tasks
//
export async function testSleepHandler(data: ITestSleepData, workingDirectory: string, context: IWorkerContext): Promise<ITestSleepResult> {
    await sleep(data.sleepMs);
    return { slept: data.sleepMs };
}

