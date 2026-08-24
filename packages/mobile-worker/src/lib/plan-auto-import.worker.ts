import type { ITaskContext } from "task-queue";
import { planMobileAutoImport } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { readAutoImportConfigFile } from "node-api/src/lib/auto-import-config.worker";

//
// The task that decides what a background automatic import pass should do.
//
// The native background import (the Android foreground service, and the iOS driver) has to know
// whether automatic import is switched on, which database it writes to, and what it watches. It asks
// this task rather than reading the settings file itself, so the file format is defined and parsed in
// exactly one place, in TypeScript, rather than once per platform in a native language.
//
// It hands back the tasks a pass has to run, ready to queue, rather than the pieces a caller would
// assemble them from. Native code then forwards each one unchanged and never builds a task payload
// of its own, so what a pass does is decided and tested here, and the two platforms cannot drift
// apart by assembling it differently.
//
// The deciding is planMobileAutoImport, which the app itself uses, so the service and the interface
// cannot disagree about whether automatic import is running.
//

//
// One task a pass runs, in the order it is given.
//
export interface IAutoImportPassStep {
    // The task type to queue.
    type: string;

    // The input data to queue it with.
    data: object;
}

//
// The outputs of the plan-auto-import task: what a pass should do right now.
//
export interface IPlanAutoImportResult {
    // Whether a pass should run at all. False stops the background import.
    shouldRun: boolean;

    // The sandbox-relative path of the database a pass imports into.
    databasePath: string;

    // True when no default database has been chosen yet, so the path above is where a new one goes
    // and the steps below start by creating it.
    isNewDefault: boolean;

    // The settings a pass runs with.
    settings: IAutoImportSettings;

    // How long to wait after a pass finishes before starting the next one, in milliseconds.
    pauseBetweenRunsMs: number;

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: IAutoImportPassStep[];
}

//
// Handler for the plan-auto-import task.
//
export async function planAutoImportHandler(_data: object, context: ITaskContext): Promise<IPlanAutoImportResult> {
    const contents = await readAutoImportConfigFile(AUTO_IMPORT_CONFIG_PATH);
    const plan = planMobileAutoImport(contents.settings, contents.defaultDatabasePath);

    const steps: IAutoImportPassStep[] = [];

    if (plan.shouldRun) {
        if (plan.isNewDefault) {
            // The database first, then the record of it. Recorded before the import rather than
            // after, because an import that fails must not leave the next pass creating the database
            // a second time on top of the one that is already there.
            steps.push({
                type: "create-database",
                data: {
                    databasePath: plan.databasePath,
                },
            });
            steps.push({
                type: "record-default-database",
                data: {
                    databasePath: plan.databasePath,
                },
            });
        }

        // One import task per pass, the same kind of task a manual import runs. It reads its sources
        // to the end and finishes, which is what makes a pass a pass: the loop above it decides when
        // the next one starts.
        steps.push({
            type: "import-assets",
            data: {
                paths: [],
                storageDescriptor: {
                    databasePath: plan.databasePath,
                },
                sessionId: context.uuidGenerator.generate(),
                dryRun: false,
                options: {
                    auto: true,
                    ...plan.settings,
                },
            },
        });
    }

    return {
        shouldRun: plan.shouldRun,
        databasePath: plan.databasePath,
        isNewDefault: plan.isNewDefault,
        settings: plan.settings,
        pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
        steps,
    };
}
