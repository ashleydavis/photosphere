import { dialog, BrowserWindow } from 'electron';
import { join, dirname } from 'path';
import { loadDesktopConfig, saveDesktopConfig, updateLastDownloadFolder } from 'node-api';
import type { IDesktopConfig } from 'node-api';

//
// Options for the native folder picker dialog.
//
export interface IPickFolderOptions {
    // Window title shown in the native dialog.
    title?: string;

    // Config key to read the default path from and persist the chosen path back to.
    // Maps directly to a key in IDesktopConfig ('lastFolder' is the existing default).
    folderKey?: string;

    // Whether to show the "New Folder" button.
    createDirectory?: boolean;
}

//
// Shows a directory picker dialog, focusing the main window first if available.
// Reads the default path from and persists the chosen path back to the config key
// specified by `options.folderKey` (defaults to 'lastFolder').
// Returns the selected path, or undefined if the user cancelled.
//
export async function pickFolder(mainWindow: BrowserWindow | null, options?: IPickFolderOptions): Promise<string | undefined> {
    const title = options?.title || 'Select Folder';
    const folderKey = options?.folderKey || 'lastFolder';
    const createDirectory = options?.createDirectory === true;

    // Test-mode override: the smoke test for multi-asset download sets
    // PHOTOSPHERE_TEST_DOWNLOAD_FOLDER so the renderer does not block on a native dialog.
    if (process.env.PHOTOSPHERE_TEST_MODE === '1' && process.env.PHOTOSPHERE_TEST_DOWNLOAD_FOLDER && folderKey === 'lastDownloadFolder') {
        return process.env.PHOTOSPHERE_TEST_DOWNLOAD_FOLDER;
    }

    if (mainWindow) {
        if (mainWindow.isMinimized()) {
            mainWindow.restore();
        }
        mainWindow.focus();
    }

    const config = await loadDesktopConfig();
    const configRecord = config as Record<string, IDesktopConfig[keyof IDesktopConfig]>;
    const defaultPath = configRecord[folderKey] as string | undefined;

    const properties: Electron.OpenDialogOptions['properties'] = ['openDirectory'];
    if (createDirectory) {
        properties.push('createDirectory');
    }
    const dialogOptions: Electron.OpenDialogOptions = {
        properties,
        title,
        defaultPath,
    };
    const result = mainWindow
        ? await dialog.showOpenDialog(mainWindow, dialogOptions)
        : await dialog.showOpenDialog(dialogOptions);

    if (result.canceled || result.filePaths.length === 0) {
        return undefined;
    }

    const chosen = result.filePaths[0];
    configRecord[folderKey] = chosen;
    await saveDesktopConfig(config);
    return chosen;
}

//
// Shows a save-file dialog with a default path derived from the last download folder.
// On confirm, persists the chosen folder to `lastDownloadFolder` and returns the
// chosen file path. Returns undefined if the user cancelled.
//
export async function pickFile(mainWindow: BrowserWindow | null, defaultFilename: string): Promise<string | undefined> {
    // Test-mode override: the smoke test for single-asset download sets
    // PHOTOSPHERE_TEST_PICK_FILE_PATH so the renderer does not block on a native dialog.
    if (process.env.PHOTOSPHERE_TEST_MODE === '1' && process.env.PHOTOSPHERE_TEST_PICK_FILE_PATH) {
        return process.env.PHOTOSPHERE_TEST_PICK_FILE_PATH;
    }

    const config = await loadDesktopConfig();
    const defaultPath = config.lastDownloadFolder
        ? join(config.lastDownloadFolder, defaultFilename)
        : defaultFilename;

    const result = mainWindow
        ? await dialog.showSaveDialog(mainWindow, { defaultPath })
        : await dialog.showSaveDialog({ defaultPath });

    if (result.canceled || !result.filePath) {
        return undefined;
    }

    await updateLastDownloadFolder(dirname(result.filePath));
    return result.filePath;
}
