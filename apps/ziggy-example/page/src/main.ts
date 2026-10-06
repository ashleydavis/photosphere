import type { IJsonValue } from "ziggy-bridge";
import { formatPingReply, IPingReply } from "./lib/format-reply";
import { applyJobProgress, applyTaskCompleted, emptyJobList, IJobList, IJobProgressMessage } from "./lib/job-list";
import { makeLargePayload } from "./lib/large-payload";
import { crc32 } from "./lib/crc32";
import { ITestCommand, performDropFileCommand, performInsertCommand, performTestCommand, performViewportCommand, testResultToJson } from "./lib/test-commands";
import { aboutText, buttonForMenuAction } from "./lib/menu-actions";
import { formatPicked } from "./lib/picked-paths";

//
// What a task-message event carries.
//
interface ITaskMessageEvent {
    // The task that sent the message.
    taskId: string;

    // The source the task was queued under.
    source: string;

    // The message the task sent.
    message: IOutputMessage | IJobProgressMessage | IMediaServerMessage;
}

//
// A message that tells the page the media server is listening.
//
interface IMediaServerMessage {
    // Always "media-server".
    type: "media-server";

    // The loopback port the server listens on.
    port: number;
}

//
// A message whose text the page shows in its output area.
//
interface IOutputMessage {
    // Always "output".
    type: "output";

    // The text to show.
    text: string;
}

//
// What a task-completed event carries.
//
interface ITaskCompletedEvent {
    // The task that ended.
    taskId: string;

    // The source the task was queued under.
    source: string;

    // How it ended.
    status: "succeeded" | "failed" | "cancelled";

    // What it returned, when it succeeded with a result.
    result?: IJsonValue;

    // Why it failed, when it did.
    error?: string;
}

//
// The reply of the payload-stats channel.
//
interface IPayloadStats {
    // The length in bytes of the text that arrived.
    length: number;

    // The CRC-32 of those bytes.
    crc32: number;
}

//
// The reply of the file-roundtrip channel.
//
interface IFileRoundtrip {
    // The file that was written.
    path: string;

    // What was read back from it.
    text: string;
}
//
// What a menu-action event carries.
//
interface IMenuActionEvent {
    // The action of the menu item that was chosen.
    action: string;
}


//
// A command from the test control connection, with the id the answer must carry.
//
interface ITestCommandEvent {
    // Identifies the command so its answer reaches the right waiting connection.
    requestId: number;

    // The command to perform.
    command: ITestCommand;
}

function element(dataId: string): HTMLElement {
    const found = document.querySelector<HTMLElement>(`[data-id="${dataId}"]`);
    if (!found) {
        throw new Error(`The page has no element with the data-id ${dataId}.`);
    }
    return found;
}

function appendTo(dataId: string, text: string): void {
    const target = element(dataId);
    target.textContent = `${target.textContent}${text}\n`;
    target.scrollTop = target.scrollHeight;
}

let jobList: IJobList = emptyJobList();
let nextTaskNumber = 1;

function renderJobs(): void {
    const list = element("jobs");
    list.textContent = "";
    for (const job of jobList.jobs) {
        const item = document.createElement("li");
        item.textContent = `${job.name}: ${job.progressMessage ?? ""}`;
        list.appendChild(item);
    }
}

function queueTask(taskType: string, source: string, data: IJsonValue): string {
    const taskId = `${taskType}-${nextTaskNumber++}`;
    window.ziggy.send("add-task", {
        taskId,
        taskType,
        source,
        data,
        priority: 0,
    });
    return taskId;
}

function jobTag(name: string, source: string): IJsonValue {
    return {
        id: `job-${nextTaskNumber}`,
        name,
        cancelSource: source,
    };
}

async function showReply(): Promise<void> {
    const reply = await window.ziggy.invoke<IPingReply>("ping", { greeting: "hello from the page" });
    element("reply").textContent = formatPingReply(reply);
}

function startTasks(): void {
    element("start-short").addEventListener("click", () => {
        queueTask("hello-short", "short-source", { job: jobTag("Short job", "short-source") });
    });
    element("start-long").addEventListener("click", () => {
        const children = Number((element("child-count") as HTMLInputElement).value);
        queueTask("hello-long", "long-source", {
            durationMs: 3000,
            stepMs: 100,
            children,
            job: jobTag("Long job", "long-source"),
        });
    });
    element("start-many").addEventListener("click", () => {
        for (let index = 1; index <= 3; index++) {
            const source = `many-${index}`;
            queueTask("hello-long", source, {
                durationMs: 3000,
                stepMs: 100,
                children: 0,
                job: jobTag(`Many job ${index}`, source),
            });
        }
    });
    element("cancel-source").addEventListener("click", () => {
        window.ziggy.send("cancel-tasks", { source: "long-source" });
    });
    element("cancel-many-first").addEventListener("click", () => {
        window.ziggy.send("cancel-tasks", { source: "many-1" });
    });
    element("start-fail").addEventListener("click", () => {
        queueTask("hello-fail", "fail-source", null);
    });
    // The two background tasks count in a file in the app's data directory for fifteen seconds. The keep-alive one keeps the app
    // running when its window is closed or it leaves the foreground, and the normal one does not.
    element("start-keep-alive").addEventListener("click", () => {
        queueTask("background-keep-alive", "keep-alive-source", { file: "keep-alive.txt", durationMs: 15000 });
    });
    element("start-background-normal").addEventListener("click", () => {
        queueTask("background-normal", "background-normal-source", { file: "normal.txt", durationMs: 15000 });
    });
    element("os-version").addEventListener("click", () => {
        queueTask("os-version", "os-source", null);
    });
}

function startEdgeChecks(): void {
    const result = element("edge-result");
    element("send-large").addEventListener("click", async () => {
        const text = makeLargePayload(5 * 1024 * 1024);
        const stats = await window.ziggy.invoke<IPayloadStats>("payload-stats", { text });
        const expectedLength = new TextEncoder().encode(text).length;
        const matches = stats.length === expectedLength && stats.crc32 === crc32(text);
        result.textContent = matches ? `large payload ok: ${stats.length} bytes` : `large payload WRONG: sent ${expectedLength} bytes, core saw ${stats.length}`;
    });
    element("send-unicode").addEventListener("click", async () => {
        const text = "say \"hi\"\nline two é 世界 😀";
        const stats = await window.ziggy.invoke<IPayloadStats>("payload-stats", { text });
        const matches = stats.length === new TextEncoder().encode(text).length && stats.crc32 === crc32(text);
        result.textContent = matches ? "unicode ok" : "unicode WRONG";
    });
    element("file-roundtrip").addEventListener("click", async () => {
        const text = "written by Zig é 世界";
        const reply = await window.ziggy.invoke<IFileRoundtrip>("file-roundtrip", { text });
        result.textContent = reply.text === text ? "file ok" : "file WRONG";
    });
    element("invoke-fail").addEventListener("click", async () => {
        try {
            await window.ziggy.invoke<IJsonValue>("fail", null);
            result.textContent = "failing channel did not fail";
        }
        catch (error) {
            result.textContent = `error reply: ${(error as Error).message}`;
        }
    });
}
//
// The file and folder pickers. Each is a request to the core on the Electron app's channel for it, and the reply is shown in
// the page. A cancelled dialog replies null.
//
function startPickers(): void {
    const picked = element("picked");
    element("pick-files").addEventListener("click", async () => {
        const paths = await window.ziggy.invoke<string[] | null>("pick-files", "Select files");
        picked.textContent = formatPicked("pick-files", paths);
    });
    element("pick-folder").addEventListener("click", async () => {
        const path = await window.ziggy.invoke<string | null>("pick-folder", { title: "Select folder" });
        picked.textContent = formatPicked("pick-folder", path);
    });
    element("pick-file").addEventListener("click", async () => {
        const path = await window.ziggy.invoke<string | null>("pick-file", "example.txt");
        picked.textContent = formatPicked("pick-file", path);
    });
}


//
// Loads the example image and video from the media server on the loopback port, and asks it for a range of bytes with a
// request from the page's script, which the browser lets through only because the server allows the page's origin. The
// status shows what each of the three did.
//
function showMedia(port: number): void {
    const base = `http://127.0.0.1:${port}`;
    const image = element("media-image") as HTMLImageElement;
    const video = element("media-video") as HTMLVideoElement;
    image.addEventListener("load", () => {
        appendTo("media-status", `image loaded ${image.naturalWidth}x${image.naturalHeight}`);
    });
    image.addEventListener("error", () => {
        appendTo("media-status", "image failed");
    });
    video.addEventListener("loadedmetadata", () => {
        appendTo("media-status", `video loaded ${video.duration.toFixed(1)}s`);
    });
    video.addEventListener("error", () => {
        appendTo("media-status", `video failed ${video.error?.message ?? ""}`);
    });
    image.src = `${base}/example.png`;
    video.src = `${base}/example.mp4`;
    fetch(`${base}/example.mp4`, { headers: { Range: "bytes=0-9" } })
        .then(async response => {
            const bytes = await response.arrayBuffer();
            appendTo("media-status", `range fetch ${response.status} ${bytes.byteLength} bytes`);
        })
        .catch(error => {
            appendTo("media-status", `range fetch failed ${(error as Error).message}`);
        });
}

function startMedia(): void {
    element("start-media").addEventListener("click", () => {
        queueTask("media-server", "media-source", null);
    });
    element("cancel-media").addEventListener("click", () => {
        window.ziggy.send("cancel-tasks", { source: "media-source" });
    });
}

//
// Files dropped on the drop zone, written the way a page written for Electron would: for each File of the drop it asks
// window.ziggy.getPathForFile for the real path. A drop anywhere else does nothing, rather than the web view navigating to the file.
//
function startDrop(): void {
    const zone = element("drop-zone");
    document.addEventListener("dragover", event => event.preventDefault());
    document.addEventListener("drop", event => event.preventDefault());
    zone.addEventListener("drop", event => {
        event.preventDefault();
        const files = Array.from(event.dataTransfer?.files ?? []);
        if (files.length === 0) {
            appendTo("drop-result", "dropped: no files");
        }
        for (const file of files) {
            appendTo("drop-result", `dropped: ${window.ziggy.getPathForFile(file) ?? "no path"}`);
        }
    });
}

//
// The value the storage buttons write, which has non-ASCII characters so the round trip through storage is checked too.
//
const storedValue = "kept é 世界 😀";

//
// Opens the example's IndexedDB database, creating its one store the first time.
//
function openDatabase(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
        const request = indexedDB.open("ziggy-example", 1);
        request.onupgradeneeded = () => {
            request.result.createObjectStore("values");
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
}

//
// Runs one request against the store and resolves with its result once the transaction has committed.
//
async function useStore<TResult>(mode: IDBTransactionMode, makeRequest: (store: IDBObjectStore) => IDBRequest<TResult>): Promise<TResult> {
    const database = await openDatabase();
    try {
        return await new Promise<TResult>((resolve, reject) => {
            const transaction = database.transaction("values", mode);
            const request = makeRequest(transaction.objectStore("values"));
            transaction.oncomplete = () => resolve(request.result);
            transaction.onerror = () => reject(transaction.error);
            transaction.onabort = () => reject(transaction.error);
        });
    }
    finally {
        database.close();
    }
}

//
// Writes a value to localStorage and to IndexedDB, and reads both back, so a smoke test can quit the app, start it again and
// see whether the web view kept them.
//
function startStorage(): void {
    const status = element("storage-status");
    element("storage-write").addEventListener("click", async () => {
        localStorage.setItem("ziggy-example-value", storedValue);
        await useStore("readwrite", store => store.put(storedValue, "ziggy-example-value"));
        status.textContent = "written";
    });
    element("storage-read").addEventListener("click", async () => {
        const fromDatabase = await useStore<string | undefined>("readonly", store => store.get("ziggy-example-value"));
        status.textContent = `localStorage: ${localStorage.getItem("ziggy-example-value") ?? "none"}; indexedDB: ${fromDatabase ?? "none"}`;
    });
}

function listenForEvents(): void {
    window.ziggy.onMessage<ITaskMessageEvent>("task-message", event => {
        appendTo("event-log", `task-message ${event.taskId} ${JSON.stringify(event.message)}`);
        if (event.message.type === "output") {
            appendTo("output", event.message.text);
        }
        else if (event.message.type === "job-progress") {
            jobList = applyJobProgress(jobList, event.taskId, event.message);
            renderJobs();
        }
        else if (event.message.type === "media-server") {
            showMedia(event.message.port);
        }
    });
    window.ziggy.onMessage<ITaskCompletedEvent>("task-completed", event => {
        appendTo("event-log", `task-completed ${event.taskId} ${event.status}${event.error ? ` ${event.error}` : ""}`);
        jobList = applyTaskCompleted(jobList, event.taskId);
        renderJobs();
        if (event.taskId.startsWith("os-version") && event.status === "succeeded") {
            element("edge-result").textContent = `operating system: ${String(event.result)}`;
        }
    });
}

//
// Does what a menu item asks that the shell did not do itself. A task action presses the same button the page shows.
//
function listenForMenuActions(): void {
    window.ziggy.onMessage<IMenuActionEvent>("menu-action", event => {
        appendTo("event-log", `menu-action ${event.action}`);
        const buttonId = buttonForMenuAction(event.action);
        if (buttonId !== null) {
            element(buttonId).click();
        }
        else if (event.action === "about") {
            element("edge-result").textContent = aboutText;
        }
        else {
            throw new Error(`The page does not know the menu action ${event.action}.`);
        }
    });
}

//
// Answers the commands the test control connection forwards. It does nothing unless the shell started the page in test
// mode, which it does only in a test hooks build, and it tells the core when it is listening so that no command is sent
// before it can be heard.
//
function listenForTestCommands(): void {
    if (new URLSearchParams(window.location.search).get("testMode") !== "1") {
        return;
    }
    window.ziggy.onMessage<ITestCommandEvent>("test-command", async event => {
        const finder = {
            find: (dataId: string) => document.querySelector<HTMLElement>(`[data-id="${dataId}"]`) as HTMLInputElement | null,
        };
        const result = event.command.command === "viewport"
            ? performViewportCommand(window.innerWidth, window.innerHeight)
            : event.command.command === "insert"
                ? performInsertCommand(finder, event.command, text => document.execCommand("insertText", false, text))
                : event.command.command === "drop-file"
                ? performDropFileCommand(finder, event.command, (fileName, fileSize) => {
                    const transfer = new DataTransfer();
                    transfer.items.add(new File([new Uint8Array(fileSize)], fileName));
                    return new DragEvent("drop", {
                        dataTransfer: transfer,
                        bubbles: true,
                        cancelable: true,
                    });
                })
                : performTestCommand(finder, event.command);
        await window.ziggy.invoke<IJsonValue>("test-result", {
            requestId: event.requestId,
            result: testResultToJson(result),
        });
    });
    window.ziggy.send("test-page-ready", null);
}

listenForEvents();
listenForMenuActions();
listenForTestCommands();
startTasks();
startEdgeChecks();
startPickers();
startMedia();
startStorage();
startDrop();
showReply().catch(error => {
    element("reply").textContent = `The Zig core did not answer: ${(error as Error).message}`;
});
