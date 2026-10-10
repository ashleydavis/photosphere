import type { IToolsStatus } from "user-interface";

//
// The kind of device the app runs on, as the core's get-platform channel reports it.
//
export type PlatformKind = "desktop" | "mobile";

//
// What the core's get-platform channel replies with.
//
export interface IPlatformInfo {
    // Whether the app is on a desktop or a phone.
    platformKind: PlatformKind;

    // The operating system's name as Zig spells it: "linux", "windows", "macos" or "ios". Android reports "linux".
    os: string;

    // The processor architecture's name as Zig spells it.
    arch: string;
}

//
// How a desktop saves downloaded assets or a phone does.
//
export type DownloadMethod = "save-dialog" | "share-sheet";

//
// Which developer console the platform opens.
//
export type DevToolsKind = "shell" | "eruda";

//
// What differs between a desktop and a phone, as data the platform provider reads instead of asking which platform it is on.
//
export interface IPlatformCapabilities {
    // Whether files can be dropped on the window to import them.
    supportsDragAndDropImport: boolean;

    // What the automatic import card says about importing while the app is not on screen.
    backgroundImportDescription: string;

    // Whether the real path of a dropped File can be read from it.
    readsDroppedFilePaths: boolean;

    // Whether the app can show a dialog to choose a database to open.
    opensDatabaseWithDialog: boolean;

    // Whether a folder can be shown in the system's file manager.
    opensFolders: boolean;

    // Whether an image can be copied to the clipboard.
    copiesImagesToClipboard: boolean;

    // Which developer console the toggle opens: the shell's own or the in-page Eruda console.
    devToolsKind: DevToolsKind;

    // Whether the core is asked which of the media tools are installed. A phone bundles them, so it never asks.
    asksCoreForTools: boolean;

    // How downloaded assets reach the user.
    downloadMethod: DownloadMethod;

    // Whether the app runs the background work (automatic import, sync and prefetch) with the app off screen, which a phone does.
    runsBackgroundWork: boolean;

    // Whether the desktop-only parts of the page (the MCP server's tool handler and the preview banner) are shown.
    showsDesktopChrome: boolean;
}

//
// The text the automatic import card shows on a desktop, where the import runs while the app is open.
//
const desktopBackgroundImportDescription = "Runs whenever Photosphere is open, importing new photos as they appear.";

//
// The text the automatic import card shows on iOS, where the system decides when a background import runs.
//
const iosBackgroundImportDescription = "When the app is not open, iOS decides when to catch up, usually while the phone is charging.";

//
// The text the automatic import card shows on Android, which keeps importing with the screen off.
//
const androidBackgroundImportDescription = "Keeps importing when the app is closed and the screen is off, showing a notification while it does.";

//
// What the app can do on the platform the core reported.
//
export function getPlatformCapabilities(platform: IPlatformInfo): IPlatformCapabilities {
    if (platform.platformKind === "desktop") {
        return {
            supportsDragAndDropImport: true,
            backgroundImportDescription: desktopBackgroundImportDescription,
            readsDroppedFilePaths: true,
            opensDatabaseWithDialog: true,
            opensFolders: true,
            copiesImagesToClipboard: true,
            devToolsKind: "shell",
            asksCoreForTools: true,
            downloadMethod: "save-dialog",
            showsDesktopChrome: true,
            runsBackgroundWork: false,
        };
    }
    if (platform.platformKind === "mobile") {
        return {
            supportsDragAndDropImport: false,
            backgroundImportDescription: platform.os === "ios" ? iosBackgroundImportDescription : androidBackgroundImportDescription,
            readsDroppedFilePaths: false,
            opensDatabaseWithDialog: false,
            opensFolders: false,
            copiesImagesToClipboard: false,
            devToolsKind: "eruda",
            asksCoreForTools: false,
            downloadMethod: "share-sheet",
            showsDesktopChrome: false,
            runsBackgroundWork: true,
        };
    }
    throw new Error(`Unknown platform kind "${String(platform.platformKind)}" from get-platform.`);
}

//
// The tools status of a phone, which bundles ImageMagick and ffmpeg inside the app, so all three are available.
//
export function bundledToolsStatus(): IToolsStatus {
    return {
        magick: { available: true },
        ffprobe: { available: true },
        ffmpeg: { available: true },
        allAvailable: true,
        missingTools: [],
    };
}
