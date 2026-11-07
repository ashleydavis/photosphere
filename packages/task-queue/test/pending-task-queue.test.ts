import { insertTaskByPriority, resolveTaskPriority } from "../src/lib/pending-task-queue";
import { DEFAULT_TASK_PRIORITY, TaskPriority, TaskStatus } from "../src/lib/types";
import type { ITask } from "../src/lib/types";

//
// Makes a pending task with the given id and priority. Nothing else about the task matters to the
// ordering, which is the point: these two functions decide order and nothing else.
//
function pendingTask(id: string, priority: TaskPriority): ITask<any> {
    return {
        id,
        type: "test-type",
        status: TaskStatus.Pending,
        data: {},
        source: "test-source",
        priority,
        createdAt: new Date("2026-01-01T00:00:00.000Z"),
    };
}

//
// The ids of the tasks in a pending queue, in the order they will be dispatched.
//
function idsOf(pendingTasks: ITask<any>[]): string[] {
    return pendingTasks.map(task => task.id);
}

describe("resolveTaskPriority", () => {

    test("a task that asked for nothing and has no parent runs at the default", () => {
        expect(resolveTaskPriority(undefined, undefined)).toBe(DEFAULT_TASK_PRIORITY);
    });

    test("the default is background, so nothing gets ahead of the user by accident", () => {
        expect(DEFAULT_TASK_PRIORITY).toBe(TaskPriority.Background);
    });

    test("a child that asked for nothing inherits its parent's priority", () => {
        expect(resolveTaskPriority(undefined, TaskPriority.Interactive)).toBe(TaskPriority.Interactive);
        expect(resolveTaskPriority(undefined, TaskPriority.Background)).toBe(TaskPriority.Background);
    });

    test("a priority the caller asked for beats the parent's", () => {
        expect(resolveTaskPriority(TaskPriority.Background, TaskPriority.Interactive)).toBe(TaskPriority.Background);
        expect(resolveTaskPriority(TaskPriority.Interactive, TaskPriority.Background)).toBe(TaskPriority.Interactive);
    });
});

describe("insertTaskByPriority", () => {

    test("an interactive task is dispatched before background tasks already queued", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("background-1", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("background-2", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));

        expect(idsOf(pendingTasks)).toEqual(["interactive-1", "background-1", "background-2"]);
    });

    test("a later interactive task goes in front of an earlier one still waiting", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("background-1", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-2", TaskPriority.Interactive));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-3", TaskPriority.Interactive));

        // Every interactive task goes on the head, so the most recent tap is served first and all of
        // them are still ahead of the background work.
        expect(idsOf(pendingTasks)).toEqual(["interactive-3", "interactive-2", "interactive-1", "background-1"]);
    });

    test("arrival order is kept among background tasks", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("background-1", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("background-2", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));
        insertTaskByPriority(pendingTasks, pendingTask("background-3", TaskPriority.Background));

        expect(idsOf(pendingTasks)).toEqual(["interactive-1", "background-1", "background-2", "background-3"]);
    });

    test("an interactive task queued when nothing is waiting goes straight to the front", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));

        expect(idsOf(pendingTasks)).toEqual(["interactive-1"]);
    });

    test("an interactive task goes on the head of a queue that holds nothing else", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));
        insertTaskByPriority(pendingTasks, pendingTask("background-1", TaskPriority.Background));

        expect(idsOf(pendingTasks)).toEqual(["interactive-1", "background-1"]);
    });

    test("a background task never overtakes anything, whatever is already waiting", () => {
        const pendingTasks: ITask<any>[] = [];
        insertTaskByPriority(pendingTasks, pendingTask("background-1", TaskPriority.Background));
        insertTaskByPriority(pendingTasks, pendingTask("interactive-1", TaskPriority.Interactive));
        insertTaskByPriority(pendingTasks, pendingTask("background-2", TaskPriority.Background));

        expect(idsOf(pendingTasks)).toEqual(["interactive-1", "background-1", "background-2"]);
    });
});
