import { RandomUuidGenerator, TimestampProvider, log } from "utils";
import { TaskStatus, setQueueBackend } from "task-queue";
import { WorkerPoolInline } from "./lib/worker-pool-inline";
import express from "express";
import { createServer } from "http";
import { WebSocketServer, type WebSocket } from "ws";
import { createAssetServer } from "rest-api";
import { exec } from "child_process";
import { promisify } from "util";
import * as path from "path";
import { createDatabase, createMediaFileDatabase, loadDesktopConfig, saveDesktopConfig, getDatabases, addDatabaseEntry, removeDatabaseEntry, updateLastFolder, markDatabaseOpened } from "node-api";
import { createStorage } from "storage";

const execAsync = promisify(exec);

const PORT = 3001;

const uuidGenerator = new RandomUuidGenerator();
const timestampProvider = new TimestampProvider();
const sessionId = uuidGenerator.generate();
const workerPool = new WorkerPoolInline(10, uuidGenerator, timestampProvider, { verbose: true, sessionId });
setQueueBackend(workerPool);


// Create Express app for HTTP routes
const app = express();

// Enable CORS for all routes
app.use((req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
    if (req.method === "OPTIONS") {
        res.sendStatus(200);
        return;
    }
    next();
});

// Attach asset server routes to existing Express app
await createAssetServer({
    app,
    uuidGenerator,
    timestampProvider,
    sessionId,
});

// Create HTTP server from Express app
const server = createServer(app);

// Create WebSocket server attached to the same HTTP server
const wss = new WebSocketServer({ server });

//
// Holds the sync scheduling state for a single WebSocket connection.
// Created per connection and passed to the global sync helpers below.
//
interface IConnectionSyncState {
    //
    // Absolute path of the database currently open on this connection, or null.
    //
    currentDatabasePath: string | null;

    //
    // Timer for the debounced sync triggered by edit notifications.
    //
    syncDebounceTimer: NodeJS.Timeout | null;

    //
    // Timer for the periodic sync interval.
    //
    syncPeriodicTimer: NodeJS.Timeout | null;

    //
    // True while a sync task is queued or running; prevents concurrent syncs.
    //
    isSyncRunning: boolean;
}

//
// Queues a sync-database task if a database is open and no sync is already running.
//
function enqueueSyncTask(state: IConnectionSyncState): void {
    if (!state.currentDatabasePath || state.isSyncRunning) {
        return;
    }
    state.isSyncRunning = true;
    log.info(`Queuing sync task for "${state.currentDatabasePath}"`);
    workerPool.addTask("sync-database", { databasePath: state.currentDatabasePath }, state.currentDatabasePath);
}

//
// Marks that the sync task has stopped, allowing the next sync to be queued.
//
function syncStopped(state: IConnectionSyncState): void {
    state.isSyncRunning = false;
}

//
// Cancels any running sync task, clears the running flag, and clears the debounce timer.
// Call this whenever the active database changes or the connection closes.
//
function resetSyncState(state: IConnectionSyncState): void {
    if (state.currentDatabasePath) {
        workerPool.cancelTasks(state.currentDatabasePath);
    }
    syncStopped(state);
    if (state.syncDebounceTimer !== null) {
        clearTimeout(state.syncDebounceTimer);
        state.syncDebounceTimer = null;
    }
}

//
// Schedules a debounced sync 10 seconds after the last edit notification.
// Resets the debounce timer if called again before it fires.
//
function scheduleSync(state: IConnectionSyncState): void {
    if (state.syncDebounceTimer !== null) {
        clearTimeout(state.syncDebounceTimer);
    }
    log.info("Sync debounce triggered");
    state.syncDebounceTimer = setTimeout(() => {
        state.syncDebounceTimer = null;
        enqueueSyncTask(state);
    }, 10_000);
}

//
// Starts a periodic sync timer that fires every 60 seconds.
// No-op if the timer is already running.
//
function startPeriodicSync(state: IConnectionSyncState): void {
    if (state.syncPeriodicTimer !== null) {
        return;
    }
    state.syncPeriodicTimer = setInterval(() => {
        enqueueSyncTask(state);
    }, 5 * 60 * 1_000);
}

//
// Stops the periodic sync timer.
//
function stopPeriodicSync(state: IConnectionSyncState): void {
    if (state.syncPeriodicTimer !== null) {
        clearInterval(state.syncPeriodicTimer);
        state.syncPeriodicTimer = null;
    }
}

wss.on("connection", (ws: WebSocket) => {
    console.log("WebSocket connection opened");

    // Per-connection sync state — automatically cleaned up when the client disconnects.
    const syncState: IConnectionSyncState = {
        currentDatabasePath: null,
        syncDebounceTimer: null,
        syncPeriodicTimer: null,
        isSyncRunning: false,
    };

    startPeriodicSync(syncState);

    // Set up task completion handler to send results back to this client
    const unsubscribeTaskComplete = workerPool.onTaskComplete(async (result) => {
        ws.send(JSON.stringify({
            type: "task-completed",
            taskId: result.taskId,
            result: result,
        }));
        if (result.type === "sync-database") {
            syncStopped(syncState);
            if (result.status !== TaskStatus.Succeeded) {
                ws.send(JSON.stringify({ type: "sync-completed" }));
            }
        }
    });

    // Set up task message handler to send messages back to this client
    const unsubscribeTaskMessage = workerPool.onAnyTaskMessage(data => {
        ws.send(JSON.stringify({
            type: "task-message",
            ...data,
        }));
        if (data.message.type === "sync-started") {
            log.info("Sync started");
            ws.send(JSON.stringify({ type: "sync-started" }));
        }
        else if (data.message.type === "sync-completed") {
            log.info("Sync completed");
            ws.send(JSON.stringify({ type: "sync-completed" }));
        }
    });

    ws.on("message", async (message: Buffer) => {
        try {
            const messageData = JSON.parse(message.toString());

            if (messageData.type === "add-task") {
                // Queue the task using the client-provided task ID and source
                const taskId = workerPool.addTask(messageData.taskType, messageData.data, messageData.source, messageData.taskId);
                console.log(`Queued task ${taskId} of type ${messageData.taskType}`);
            }
            else if (messageData.type === "cancel-tasks") {
                workerPool.cancelTasks(messageData.source);
            }
            else if (messageData.type === "open-database") {
                // Handle database opening request
                await handleOpenDatabase(ws);
            }
            else if (messageData.type === "create-database") {
                // Handle database creation request
                await handleCreateDatabase(ws);
            }
            else if (messageData.type === "remove-database") {
                // Handle database removal request
                await handleRemoveDatabase(ws, messageData.databasePath);
            }
            else if (messageData.type === "get-recent-databases") {
                // Handle request for recent databases list
                await handleGetRecentDatabases(ws);
            }
            else if (messageData.type === "notify-database-opened") {
                resetSyncState(syncState);
                syncState.currentDatabasePath = messageData.databasePath;
                await handleNotifyDatabaseOpened(ws, messageData.databasePath, messageData.requestId);
            }
            else if (messageData.type === "notify-database-closed") {
                resetSyncState(syncState);
                syncState.currentDatabasePath = null;
                await handleNotifyDatabaseClosed(ws, messageData.requestId);
            }
            else if (messageData.type === "notify-database-edited") {
                scheduleSync(syncState);
            }
            else if (messageData.type === "get-config") {
                await handleGetConfig(ws, messageData.key, messageData.requestId);
            }
            else if (messageData.type === "set-config") {
                await handleSetConfig(ws, messageData.key, messageData.value, messageData.requestId);
            }
            else if (messageData.type === "pick-files") {
                await handlePickFiles(ws, messageData.title, messageData.requestId);
            }
            else if (messageData.type === "pick-folder") {
                await handlePickFolder(ws, messageData.options, messageData.requestId);
            }
        }
        catch (error) {
            console.error("Error handling WebSocket message:", error);
            ws.send(JSON.stringify({
                type: "error",
                message: error instanceof Error ? error.message : "Unknown error",
            }));
        }
    });

    ws.on("close", () => {
        console.log("WebSocket connection closed");
        unsubscribeTaskComplete();
        unsubscribeTaskMessage();
        resetSyncState(syncState);
        stopPeriodicSync(syncState);
    });
});

//
// Handles database opening request from client.
//
async function handleOpenDatabase(ws: WebSocket): Promise<void> {
    try {
        const config = await loadDesktopConfig();
        const databasePath = await showDirectoryDialog(config.lastFolder);

        if (databasePath) {
            // Save to databases list and update last folder
            const existingDbs = await getDatabases();
            if (!existingDbs.some(entry => entry.path === databasePath)) {
                await addDatabaseEntry({ name: path.basename(databasePath), description: "", path: databasePath });
            }
            const folderPath = path.dirname(databasePath);
            await updateLastFolder(folderPath);

            // Send database-opened message back to client
            ws.send(JSON.stringify({
                type: "database-opened",
                databasePath: databasePath,
            }));
        }
    }
    catch (error: any) {
        // User cancelled or error occurred
        if (error.code === 1 || error.userCancelled) {
            // User cancelled - don't send error, just return
            console.log("User cancelled database opening");
            return;
        }
        console.error("Error opening database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error opening database",
        }));
    }
}

//
// Handles database creation request from client.
// Shows a directory picker, initializes a new database there, and sends database-opened.
//
async function handleCreateDatabase(ws: WebSocket): Promise<void> {
    try {
        const config = await loadDesktopConfig();
        const databasePath = await showDirectoryDialog(config.lastFolder);

        if (databasePath) {
            const { storage, rawStorage } = createStorage(databasePath, undefined, undefined);
            const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
            await createDatabase(storage, rawStorage, uuidGenerator, database.metadataCollection);

            const existingDbs2 = await getDatabases();
            if (!existingDbs2.some(entry => entry.path === databasePath)) {
                await addDatabaseEntry({ name: path.basename(databasePath), description: "", path: databasePath });
            }
            const folderPath = path.dirname(databasePath);
            await updateLastFolder(folderPath);

            ws.send(JSON.stringify({
                type: "database-opened",
                databasePath: databasePath,
            }));
        }
    }
    catch (error: any) {
        if (error.code === 1 || error.userCancelled) {
            console.log("User cancelled database creation");
            return;
        }
        console.error("Error creating database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error creating database",
        }));
    }
}

//
// Handles database removal request from client.
//
async function handleRemoveDatabase(ws: WebSocket, databasePath: string): Promise<void> {
    try {
        const existingDbs = await getDatabases();
        const entry = existingDbs.find(dbEntry => dbEntry.path === databasePath);
        if (entry) {
            await removeDatabaseEntry(entry.name);
        }
        ws.send(JSON.stringify({
            type: "database-removed",
            databasePath: databasePath,
        }));
    }
    catch (error: any) {
        console.error("Error removing database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error removing database",
        }));
    }
}

//
// Handles request for recent databases list.
//
async function handleGetRecentDatabases(ws: WebSocket): Promise<void> {
    try {
        const databases = await getDatabases();
        ws.send(JSON.stringify({
            type: "recent-databases",
            databases: databases.map(entry => entry.path),
        }));
    }
    catch (error: any) {
        console.error("Error getting recent databases:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error getting recent databases",
        }));
    }
}

//
// Handles notification that a database was opened by the frontend.
//
async function handleNotifyDatabaseOpened(ws: WebSocket, databasePath: string, requestId: unknown): Promise<void> {
    try {
        const existingDbs = await getDatabases();
        const existing = existingDbs.find(entry => entry.path === databasePath);
        let name: string;
        if (existing) {
            name = existing.name;
        }
        else {
            name = path.basename(databasePath);
            await addDatabaseEntry({ name, description: "", path: databasePath });
        }
        await markDatabaseOpened(name);
        ws.send(JSON.stringify({ type: "notify-database-opened-ack", requestId }));
    }
    catch (error: any) {
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error notifying database opened",
        }));
    }
}

//
// Handles notification that the database was closed by the frontend.
//
async function handleNotifyDatabaseClosed(ws: WebSocket, requestId: unknown): Promise<void> {
    try {
        ws.send(JSON.stringify({ type: "notify-database-closed-ack", requestId }));
    }
    catch (error: any) {
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error notifying database closed",
        }));
    }
}

//
// Handles a request to read one value from the desktop config file.
//
async function handleGetConfig(ws: WebSocket, key: string, requestId: unknown): Promise<void> {
    try {
        const config = await loadDesktopConfig();
        ws.send(JSON.stringify({
            type: "config-value",
            requestId,
            value: (config as Record<string, unknown>)[key],
        }));
    }
    catch (error: any) {
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error getting config",
        }));
    }
}

//
// Handles a request to write one value to the desktop config file.
//
async function handleSetConfig(ws: WebSocket, key: string, value: unknown, requestId: unknown): Promise<void> {
    try {
        const config = await loadDesktopConfig();
        (config as Record<string, unknown>)[key] = value;
        await saveDesktopConfig(config);
        ws.send(JSON.stringify({ type: "config-set", requestId }));
    }
    catch (error: any) {
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error setting config",
        }));
    }
}


//
// Options accepted by the pick-folder WebSocket message.
// Mirrors IPickFolderOptions on the renderer side.
//
interface IPickFolderRequestOptions {
    //
    // Window title shown in the native dialog.
    //
    title?: string;

    //
    // Config key to read the default path from and persist the chosen path back to.
    //
    folderKey?: string;

    //
    // Whether to show the "New Folder" button (or its platform-specific equivalent).
    //
    createDirectory?: boolean;
}

//
// Handles a request to show a directory picker and respond with the chosen path.
// Reads the default path from desktop config under options.folderKey (defaults to "lastFolder"),
// persists the chosen path under the same key, and sends pick-folder-result with value=undefined when cancelled.
//
async function handlePickFolder(ws: WebSocket, options: IPickFolderRequestOptions | undefined, requestId: unknown): Promise<void> {
    const title = options?.title || "Select Folder";
    const folderKey = options?.folderKey || "lastFolder";
    const createDirectory = options?.createDirectory === true;

    try {
        const config = await loadDesktopConfig();
        const configRecord = config as Record<string, unknown>;
        const defaultPath = typeof configRecord[folderKey] === "string" ? configRecord[folderKey] as string : undefined;

        const chosen = await showDirectoryDialog(defaultPath, title, createDirectory);
        if (!chosen) {
            ws.send(JSON.stringify({ type: "pick-folder-result", requestId, value: undefined }));
            return;
        }

        configRecord[folderKey] = chosen;
        await saveDesktopConfig(config);

        ws.send(JSON.stringify({ type: "pick-folder-result", requestId, value: chosen }));
    }
    catch (error: any) {
        if (error.code === 1 || error.userCancelled) {
            ws.send(JSON.stringify({ type: "pick-folder-result", requestId, value: undefined }));
            return;
        }
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error picking folder",
        }));
    }
}

//
// Handles a request to show a multi-file open dialog and respond with the chosen paths.
// Sends pick-files-result with value=undefined when the user cancels.
//
async function handlePickFiles(ws: WebSocket, title: string, requestId: unknown): Promise<void> {
    try {
        const paths = await showFileDialog(title);
        ws.send(JSON.stringify({
            type: "pick-files-result",
            requestId,
            value: paths ?? undefined,
        }));
    }
    catch (error: any) {
        if (error.code === 1 || error.userCancelled) {
            ws.send(JSON.stringify({
                type: "pick-files-result",
                requestId,
                value: undefined,
            }));
            return;
        }
        ws.send(JSON.stringify({
            type: "error",
            requestId,
            message: error instanceof Error ? error.message : "Unknown error picking files",
        }));
    }
}

//
// Shows a multi-file open dialog using platform-specific shell commands.
// Returns the selected file paths, or null when the user cancels.
//
async function showFileDialog(title: string): Promise<string[] | null> {
    const platform = process.platform;

    if (platform === "linux") {
        try {
            const command = `zenity --file-selection --multiple --separator='\n' --title='${title.replace(/'/g, "'\\''")}'`;
            const { stdout } = await execAsync(command);
            const paths = stdout.split("\n").map(line => line.trim()).filter(line => line.length > 0);
            return paths.length > 0 ? paths : null;
        }
        catch (error: any) {
            if (error.code === 1) {
                throw { code: 1, userCancelled: true };
            }
            try {
                const command = `kdialog --getopenfilename --multiple --separate-output --title '${title.replace(/'/g, "'\\''")}'`;
                const { stdout } = await execAsync(command);
                const paths = stdout.split("\n").map(line => line.trim()).filter(line => line.length > 0);
                return paths.length > 0 ? paths : null;
            }
            catch (kdialogError: any) {
                if (kdialogError.code === 1) {
                    throw { code: 1, userCancelled: true };
                }
                throw new Error("Neither zenity nor kdialog is available. Please install one of them.");
            }
        }
    }
    else if (platform === "darwin") {
        const script = `
            tell application "System Events"
                activate
                set theFiles to choose file with prompt "${title.replace(/"/g, '\\"')}" with multiple selections allowed
                set thePaths to ""
                repeat with aFile in theFiles
                    set thePaths to thePaths & POSIX path of aFile & linefeed
                end repeat
                return thePaths
            end tell
        `;
        try {
            const { stdout } = await execAsync(`osascript -e '${script.replace(/'/g, "'\\''")}'`);
            const paths = stdout.split("\n").map(line => line.trim()).filter(line => line.length > 0);
            return paths.length > 0 ? paths : null;
        }
        catch (error: any) {
            if (error.code === 1 || error.stderr?.includes("User cancelled")) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else if (platform === "win32") {
        const script = `
            Add-Type -AssemblyName System.Windows.Forms
            $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $openFileDialog.Title = "${title.replace(/"/g, '`"')}"
            $openFileDialog.Multiselect = $true
            if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $openFileDialog.FileNames | ForEach-Object { Write-Output $_ }
            }
        `;
        try {
            const { stdout } = await execAsync(`powershell -Command "${script.replace(/\n/g, "; ")}"`);
            const paths = stdout.split("\n").map(line => line.trim()).filter(line => line.length > 0);
            return paths.length > 0 ? paths : null;
        }
        catch (error: any) {
            if (error.code === 1) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else {
        throw new Error(`Unsupported platform: ${platform}`);
    }
}

//
// Shows a directory picker dialog using platform-specific tools.
// Uses lastFolder if provided to set the initial directory.
// title controls the dialog caption (default "Open Database" for backwards compat).
// createDirectory controls whether the dialog offers a "New Folder" button (Windows) or
// uses zenity's create-folder semantics (Linux) / falls back to creating the missing dir (macOS).
//
async function showDirectoryDialog(lastFolder?: string, title: string = "Open Database", createDirectory: boolean = false): Promise<string | null> {
    const platform = process.platform;
    const escapedTitle = title.replace(/'/g, "'\\''");

    if (platform === "linux") {
        // Try zenity first (GNOME), then kdialog (KDE).
        // zenity's --file-selection --directory dialog allows the user to navigate into folders
        // they have just created, so no special createDirectory flag is needed at the dialog level.
        try {
            let command = `zenity --file-selection --directory --title='${escapedTitle}'`;
            if (lastFolder) {
                command += ` --filename="${lastFolder}"`;
            }
            const { stdout } = await execAsync(command);
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1) {
                // User cancelled
                throw { code: 1, userCancelled: true };
            }
            // zenity not available, try kdialog
            try {
                let command = `kdialog --getexistingdirectory --title '${escapedTitle}'`;
                if (lastFolder) {
                    command += ` "${lastFolder}"`;
                }
                const { stdout } = await execAsync(command);
                return stdout.trim() || null;
            }
            catch (kdialogError: any) {
                if (kdialogError.code === 1) {
                    // User cancelled
                    throw { code: 1, userCancelled: true };
                }
                throw new Error("Neither zenity nor kdialog is available. Please install one of them.");
            }
        }
    }
    else if (platform === "darwin") {
        // macOS - use osascript (AppleScript). The choose folder dialog does not natively
        // support "create new folder", so when createDirectory is true the user must enter
        // (or pre-create) the folder via Finder; the chosen path is then mkdir -p'd below.
        const script = `
            tell application "System Events"
                activate
                set folderPath to choose folder with prompt "${title.replace(/"/g, '\\"')}"
                return POSIX path of folderPath
            end tell
        `;
        try {
            const { stdout } = await execAsync(`osascript -e '${script.replace(/'/g, "'\\''")}'`);
            const chosen = stdout.trim() || null;
            return chosen;
        }
        catch (error: any) {
            if (error.code === 1 || error.stderr?.includes("User cancelled")) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else if (platform === "win32") {
        // Windows - use PowerShell
        const initialDir = lastFolder ? `$folderBrowser.SelectedPath = "${lastFolder.replace(/\\/g, "\\\\")}"` : "";
        const showNewFolder = createDirectory ? "$true" : "$false";
        const script = `
            Add-Type -AssemblyName System.Windows.Forms
            $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderBrowser.Description = "${title.replace(/"/g, '`"')}"
            $folderBrowser.ShowNewFolderButton = ${showNewFolder}
            ${initialDir}
            if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Write-Output $folderBrowser.SelectedPath
            }
        `;
        try {
            const { stdout } = await execAsync(`powershell -Command "${script.replace(/\n/g, "; ")}"`);
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else {
        throw new Error(`Unsupported platform: ${platform}`);
    }
}

// Start server
server.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT} (HTTP) and ws://localhost:${PORT} (WebSocket)`);
});

