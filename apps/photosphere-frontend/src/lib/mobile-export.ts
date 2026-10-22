import type { ISaveAssetItem } from "api";
import { TaskStatus, type ITaskResult } from "task-queue";
import type { ISaveDownloadResult } from "user-interface";

//
// Export helpers for a phone. A phone cannot write to a folder the user chooses (an iOS security-scoped address or an Android
// content:// tree is not a path the storage layer can write to), so a download is written to a temporary folder in the app's
// private storage by the save-asset or save-assets-batch task, and the native app's share or save sheet then hands the finished
// files out, deleting each temporary copy on every exit. The exportFile and exportFiles request channels of the core ask the
// native app for that sheet.
//

//
// The directory, relative to the app's private storage, that a download's finished files are written to before the share sheet
// hands them out. The native app removes each file after its sheet is dismissed.
//
export const EXPORT_TEMP_DIR = ".export-tmp";

//
// The file name used when a download's file name reduces to nothing once it is made safe, so the share sheet always has a named
// file.
//
const FALLBACK_FILENAME = "download";

//
// Reduces an arbitrary caller-supplied name to a single safe path segment: the final path component with separators and
// traversal removed, falling back to the given default when nothing is left.
//
export function sanitizePathSegment(rawName: string, fallback: string): string {
    const lastSeparator = Math.max(rawName.lastIndexOf("/"), rawName.lastIndexOf("\\"));
    const baseName = lastSeparator === -1 ? rawName : rawName.slice(lastSeparator + 1);
    const trimmed = baseName.trim();
    if (trimmed === "" || trimmed === "." || trimmed === "..") {
        return fallback;
    }
    return trimmed;
}

//
// Builds the path, relative to the app's private storage, that a single downloaded file is written to before export:
// "<EXPORT_TEMP_DIR>/<uuid>/<filename>". The per-uuid subdirectory keeps the file's real name (so the share sheet shows it)
// while avoiding collisions between successive downloads of the same name.
//
export function buildExportFilePath(filename: string, uuid: string): string {
    return `${EXPORT_TEMP_DIR}/${uuid}/${sanitizePathSegment(filename, FALLBACK_FILENAME)}`;
}

//
// Builds the throwaway folder, relative to the app's private storage, that a batch download writes its files into before
// export: "<EXPORT_TEMP_DIR>/<uuid>".
//
export function buildExportFolderPath(uuid: string): string {
    return `${EXPORT_TEMP_DIR}/${uuid}`;
}

//
// The input of the save-asset task.
//
export interface ISaveAssetTaskData {
    // The asset to write.
    assetId: string;

    // Which version of the asset to write ("asset", "display" or "thumb").
    assetType: string;

    // The path to write it to.
    destPath: string;

    // The database the asset is in.
    databasePath: string;
}

//
// The input of the save-assets-batch task.
//
export interface ISaveAssetsBatchTaskData {
    // The assets to write.
    assets: ISaveAssetItem[];

    // The folder to write them into.
    folderPath: string;

    // The database the assets are in.
    databasePath: string;
}

//
// The outputs of the save-assets-batch task.
//
export interface ISaveAssetsBatchOutputs {
    // The names of the files that were written.
    succeededFiles: string[];

    // The names of the files that could not be written.
    failedFiles: string[];
}

//
// The answer a test stages for the next export in place of the native app's share or save sheet, which no automated test can
// answer: "shared" completes as if the user chose a destination and "cancelled" as if they dismissed the sheet. Undefined in
// production, so the real sheet is shown.
//
export type ExportTestOutcome = "shared" | "cancelled";

//
// The request sent to the native app for exportFile. A staged test outcome travels in it so the native app skips its sheet.
//
export interface IExportFileRequest {
    // The finished file, relative to the app's private storage.
    path: string;

    // The staged test outcome, left out in production.
    testOutcome?: ExportTestOutcome;
}

//
// The request sent to the native app for exportFiles. A staged test outcome travels in it so the native app skips its sheet.
//
export interface IExportFilesRequest {
    // The finished files, relative to the app's private storage.
    paths: string[];

    // The staged test outcome, left out in production.
    testOutcome?: ExportTestOutcome;
}

//
// Builds the exportFile request, carrying the test outcome only when one is staged.
//
export function buildExportFileRequest(path: string, testOutcome: ExportTestOutcome | undefined): IExportFileRequest {
    if (testOutcome === undefined) {
        return {
            path,
        };
    }
    return {
        path,
        testOutcome,
    };
}

//
// Builds the exportFiles request, carrying the test outcome only when one is staged.
//
export function buildExportFilesRequest(paths: string[], testOutcome: ExportTestOutcome | undefined): IExportFilesRequest {
    if (testOutcome === undefined) {
        return {
            paths,
        };
    }
    return {
        paths,
        testOutcome,
    };
}

//
// The reply of the exportFile request.
//
export interface IExportFileReply {
    // The path that was handed out, or null when the user cancelled the sheet.
    path: string | null;
}

//
// The reply of the exportTempFolder request.
//
export interface IExportFolderReply {
    // The absolute path of the folder the native app made.
    path: string;
}

//
// The reply of the exportFiles request.
//
export interface IExportFilesReply {
    // The paths that were handed out, or null when the user cancelled the sheet.
    paths: string[] | null;
}

//
// What saving a download on a phone needs from the rest of the app.
//
export interface IMobileExportDependencies {
    // Makes the unique id that keeps one export's temporary files apart from another's.
    newUuid(): string;

    // Asks the native app to make the folder (relative to the app's private storage) that one export's files are written into,
    // and gives its absolute path, which is what the save tasks write to.
    makeExportFolder(folder: string): Promise<string>;

    // Runs a task to its end and gives its result.
    runTask(taskType: string, data: ISaveAssetTaskData | ISaveAssetsBatchTaskData): Promise<ITaskResult>;

    // Asks the native app to hand one finished file out through its share or save sheet.
    exportFile(path: string, testOutcome: ExportTestOutcome | undefined): Promise<IExportFileReply>;

    // Asks the native app to hand several finished files out through one sheet.
    exportFiles(paths: string[], testOutcome: ExportTestOutcome | undefined): Promise<IExportFilesReply>;
}

//
// Saves downloaded assets on a phone: writes them to a temporary place with the save-asset task (one file) or the
// save-assets-batch task (several), then hands them out through the native app's sheet. A task that does not succeed is a
// failed save, a sheet the user dismissed is a cancelled one, and anything else is saved.
//
export async function saveDownloadsViaShareSheet(items: ISaveAssetItem[], databasePath: string, testOutcome: ExportTestOutcome | undefined, dependencies: IMobileExportDependencies): Promise<ISaveDownloadResult> {
    if (items.length === 1) {
        const item = items[0];
        const uuid = dependencies.newUuid();
        const tempFolder = buildExportFolderPath(uuid);
        const tempPath = buildExportFilePath(item.filename, uuid);
        const absoluteFolder = await dependencies.makeExportFolder(tempFolder);
        const result = await dependencies.runTask("save-asset", {
            assetId: item.assetId,
            assetType: item.assetType,
            destPath: `${absoluteFolder}${tempPath.slice(tempFolder.length)}`,
            databasePath,
        });
        if (result.status !== TaskStatus.Succeeded) {
            return {
                outcome: "failed",
                savedCount: 0,
                failedCount: items.length,
                errorMessage: result.errorMessage,
            };
        }
        const exported = await dependencies.exportFile(tempPath, testOutcome);
        if (exported.path === null) {
            return {
                outcome: "cancelled",
                savedCount: 0,
                failedCount: 0,
            };
        }
        return {
            outcome: "saved",
            savedCount: 1,
            failedCount: 0,
        };
    }

    const tempFolder = buildExportFolderPath(dependencies.newUuid());
    const absoluteFolder = await dependencies.makeExportFolder(tempFolder);
    const result = await dependencies.runTask("save-assets-batch", {
        assets: items,
        folderPath: absoluteFolder,
        databasePath,
    });
    if (result.status !== TaskStatus.Succeeded) {
        return {
            outcome: "failed",
            savedCount: 0,
            failedCount: items.length,
            errorMessage: result.errorMessage,
        };
    }
    const outputs = result.outputs as ISaveAssetsBatchOutputs;
    if (outputs.succeededFiles.length > 0) {
        const exported = await dependencies.exportFiles(outputs.succeededFiles.map(fileName => `${tempFolder}/${fileName}`), testOutcome);
        if (exported.paths === null) {
            return {
                outcome: "cancelled",
                savedCount: 0,
                failedCount: 0,
            };
        }
    }
    return {
        outcome: "saved",
        savedCount: outputs.succeededFiles.length,
        failedCount: outputs.failedFiles.length,
    };
}
