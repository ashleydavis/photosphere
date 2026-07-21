import { JsEngine, type IJsEnginePlugin, type IExportFileOptions, type IExportFilesOptions } from "./js-engine-plugin";
import type { IPickFolderOptions } from "user-interface";

//
// Export/download destination helpers for the mobile platform provider. On mobile a foreign
// filesystem folder cannot be handed to the storage layer (an iOS security-scoped file:// URL or an
// Android content:// tree URI is not a sandbox-relative path, and PathSandbox rejects absolute
// paths), so downloads follow the photo picker's design in reverse: the download task writes the
// finished bytes to a sandbox temp path, then the native share/save sheet hands that file out and
// the temp copy is deleted. Kept as standalone functions so the copy/inject logic is unit-testable
// without rendering the React provider.
//

//
// The sandbox-relative directory a download's finished bytes are written to before the share sheet
// hands them out. The native plugin sweeps this directory on start-up to collect any temp copy left
// behind by a kill mid-sheet, and deletes each file after its sheet is dismissed.
//
export const EXPORT_TEMP_DIR = ".export-tmp";

//
// The folder name substituted when a name prompt yields something that reduces to empty after
// sanitising, so a picked database path is never the empty string.
//
const FALLBACK_NAME = "database";

//
// The file name substituted when an export filename reduces to empty after sanitising, so the
// share sheet always has a named file.
//
const FALLBACK_FILENAME = "download";

//
// Generates a unique id used to keep each export's temp path from colliding with another. Uses the
// WebView crypto.randomUUID (available in the secure Capacitor context) and falls back to a
// timestamp/random string if it is somehow unavailable.
//
function generateUuid(): string {
    const cryptoObject = globalThis.crypto;
    if (cryptoObject && typeof cryptoObject.randomUUID === "function") {
        return cryptoObject.randomUUID();
    }
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

//
// Reduces an arbitrary caller-supplied name to a single safe path segment: the final path component
// with separators and traversal removed, falling back to the given default when nothing is left.
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
// Builds the sandbox-relative path a single downloaded file is written to before export:
// "<EXPORT_TEMP_DIR>/<uuid>/<filename>". The per-uuid subdirectory keeps the file's real name (so
// the share sheet shows it) while avoiding collisions between successive downloads of the same name.
//
export function buildExportFilePath(filename: string, uuid: string): string {
    return `${EXPORT_TEMP_DIR}/${uuid}/${sanitizePathSegment(filename, FALLBACK_FILENAME)}`;
}

//
// Builds the sandbox-relative throwaway folder a batch download writes its files into before export:
// "<EXPORT_TEMP_DIR>/<uuid>".
//
export function buildExportFolderPath(uuid: string): string {
    return `${EXPORT_TEMP_DIR}/${uuid}`;
}

//
// Test-only staged result for the next pickMobileFolder call: a sandbox-relative path, or null to
// simulate the user cancelling the name prompt. Undefined in production so the real prompt runs.
// Consumed once.
//
let injectedFolderResult: string | null | undefined;

//
// Test-only staged outcome for the next export call, passed through to the native plugin so it runs
// its completion handler (including temp-file cleanup) without presenting the non-automatable sheet.
// Undefined in production so the real sheet is presented. Consumed once.
//
let injectedExportOutcome: "shared" | "cancelled" | undefined;

//
// Test-only: stages the result of the next pickMobileFolder name prompt. A string is returned as the
// picked path; null simulates the user cancelling. Called by the mobile provider on the stage-pick-
// folder smoke-test window event.
//
export function setInjectedPickFolderResult(result: string | null): void {
    injectedFolderResult = result;
}

//
// Test-only: stages the outcome of the next saveMobileDownloadedFile/saveMobileDownloadedFiles call.
// Called by the mobile provider on the stage-export smoke-test window event.
//
export function setInjectedExportOutcome(outcome: "shared" | "cancelled"): void {
    injectedExportOutcome = outcome;
}

//
// Reads and clears the staged export outcome, so each staged outcome applies to exactly one export.
//
function consumeInjectedExportOutcome(): "shared" | "cancelled" | undefined {
    const outcome = injectedExportOutcome;
    injectedExportOutcome = undefined;
    return outcome;
}

//
// Produces the sandbox-relative destination for a pickFolder call, or undefined when cancelled. On
// mobile pickFolder is the database-path "Browse" convenience: it prompts for a name and returns it
// as a sandbox-relative path, or undefined when the prompt is dismissed. In tests the result is taken
// from the staged injection instead of prompting.
//
export function pickMobileFolder(options: IPickFolderOptions | undefined): string | undefined {
    if (injectedFolderResult !== undefined) {
        const staged = injectedFolderResult;
        injectedFolderResult = undefined;
        return staged === null ? undefined : staged;
    }

    // The database path can also be typed directly into the dialog; this prompt is the "Browse"
    // convenience. window.prompt returns null when dismissed, which maps to the cancel contract.
    const promptTitle = options?.title ?? "Database name";
    const entered = window.prompt(`${promptTitle}: enter a name for the database`);
    if (entered === null) {
        return undefined;
    }
    return sanitizePathSegment(entered, FALLBACK_NAME);
}

//
// Saves one downloaded file on mobile. The download task cannot write to a user-chosen location (a
// foreign file:// or content:// destination is not a sandbox-relative path), so `writeFile` writes
// the bytes to a sandbox temp path and the native share sheet then hands the finished file out,
// deleting the temp copy on every exit. Resolves true when the file reached the user, false when the
// write failed or the user cancelled the sheet. A staged test outcome drives the sheet's result
// (including cleanup) without a real sheet.
//
export async function saveMobileDownloadedFile(filename: string, writeFile: (destinationPath: string) => Promise<boolean>, plugin: IJsEnginePlugin = JsEngine): Promise<boolean> {
    const tempPath = buildExportFilePath(filename, generateUuid());
    const wrote = await writeFile(tempPath);
    if (!wrote) {
        return false;
    }
    const options: IExportFileOptions = { path: tempPath };
    const testOutcome = consumeInjectedExportOutcome();
    if (testOutcome !== undefined) {
        options.testOutcome = testOutcome;
    }
    const result = await plugin.exportFile(options);
    return result.path !== null;
}

//
// Batch form of saveMobileDownloadedFile. `writeFiles` writes the files into a sandbox temp folder and
// returns the paths to hand out (undefined on failure); a single native share sheet then hands them
// out, deleting each temp copy on every exit. Resolves true when the files reached the user (including
// when there was nothing to hand out because every file failed), false when the write failed or the
// user cancelled the sheet.
//
export async function saveMobileDownloadedFiles(writeFiles: (destinationFolder: string) => Promise<string[] | undefined>, plugin: IJsEnginePlugin = JsEngine): Promise<boolean> {
    const tempFolder = buildExportFolderPath(generateUuid());
    const deliverPaths = await writeFiles(tempFolder);
    if (deliverPaths === undefined) {
        return false;
    }
    if (deliverPaths.length === 0) {
        return true;
    }
    const options: IExportFilesOptions = { paths: deliverPaths };
    const testOutcome = consumeInjectedExportOutcome();
    if (testOutcome !== undefined) {
        options.testOutcome = testOutcome;
    }
    const result = await plugin.exportFiles(options);
    return result.paths !== null;
}
