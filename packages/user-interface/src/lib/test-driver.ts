//
// Shared DOM test driver.
//
// In test mode the app is driven by smoke-test scripts that issue commands ("click",
// "type", ...) targeting elements by their `data-id` attribute. The same DOM-action logic
// is used by every shell (Electron desktop renderer, Android/iOS WebView). The transport
// that carries commands into the driver differs per shell (Electron IPC vs WebSocket), so
// the driver is parameterised by an ITestTransport.
//

import { TaskQueue, TaskStatus, getQueueBackend } from "task-queue";
import { RandomUuidGenerator } from "utils";

//
// The fixed pairing code and payload used by the lan-share-roundtrip test command.
//
const ROUNDTRIP_CODE = "4321";

//
// A known secret payload the roundtrip sends; the test asserts the receiver delivers it back intact.
//
const ROUNDTRIP_PAYLOAD = {
    type: "secret" as const,
    name: "roundtrip-secret",
    secretType: "api-key" as const,
    value: JSON.stringify({ apiKey: "roundtrip-value-42" }),
};

//
// Runs a full LAN-share transfer against the device's own loopback, as a single test command: it
// dispatches a real receiver task and a real sender (find-receiver then send-payload) through the same
// TaskQueue the app uses, so the whole native UDP discovery + cert-pinned HTTPS transfer runs on the
// device. Returns a JSON string describing the outcome (whether the send succeeded and what payload the
// receiver actually delivered) so the smoke test can assert an end-to-end transfer really happened.
//
async function runLanShareRoundtrip(): Promise<string> {
    // Fail clearly if the queue backend was never installed (misconfigured host), rather than hang.
    getQueueBackend();

    const queue = new TaskQueue(new RandomUuidGenerator(), "lan-share-roundtrip");
    try {
        // Start the receiver first so it is broadcasting before the sender searches.
        const receiverTaskId = queue.addTask("receive-share", { code: ROUNDTRIP_CODE });
        const receiverPromise = queue.awaitTask(receiverTaskId);

        const finderTaskId = queue.addTask("find-receiver", { code: ROUNDTRIP_CODE });
        const finderResult = await queue.awaitTask(finderTaskId);
        const endpoint = finderResult && finderResult.status === TaskStatus.Succeeded ? finderResult.outputs.endpoint : null;
        if (!endpoint) {
            return JSON.stringify({ ok: false, stage: "find-receiver", error: finderResult?.errorMessage ?? "no receiver discovered" });
        }

        const sendTaskId = queue.addTask("send-payload", { payload: ROUNDTRIP_PAYLOAD, code: ROUNDTRIP_CODE, endpoint });
        const sendResult = await queue.awaitTask(sendTaskId);
        const sendSuccess = sendResult && sendResult.status === TaskStatus.Succeeded ? sendResult.outputs.success === true : false;

        const receiverResult = await receiverPromise;
        const delivered = receiverResult && receiverResult.status === TaskStatus.Succeeded ? receiverResult.outputs.payload : null;

        return JSON.stringify({
            ok: sendSuccess && delivered != null,
            sendSuccess,
            sendStatus: sendResult ? sendResult.status : "no-result",
            sendError: sendResult ? sendResult.errorMessage ?? null : null,
            deliveredName: delivered ? delivered.name : null,
            deliveredValue: delivered ? delivered.value : null,
        });
    }
    finally {
        queue.shutdown();
    }
}

//
// Payload carried with a test command. Fields are optional because each command only uses
// the subset relevant to it (e.g. "type" uses dataId + text, "navigate" uses page).
//
export interface ITestCommandPayload {
    // The target element's `data-id` attribute (click/long-press-click/type/drop/get-value).
    dataId?: string;

    // Index of the matching element when several share the same `data-id` (defaults to 0).
    nth?: number;

    // Text to type into an input (type command).
    text?: string;

    // File paths to drop onto a drop target (drop command).
    paths?: string[];

    // Route to navigate to (navigate command).
    page?: string;

    // Menu item id (menu command).
    itemId?: string;

    // Database path (open-database command).
    path?: string;

    // Database entries to seed into the mobile config store (seed-databases command).
    databases?: ISeedDatabaseEntry[];

    // Secret records to seed into the mobile config store (seed-secrets command).
    secrets?: ISeedSecret[];

    // Database entries to seed into the recent-databases list (seed-recent command).
    recent?: ISeedDatabaseEntry[];

    // News items to seed into the mobile config store (seed-news command).
    news?: ISeedNewsItem[];
}

//
// A news item the test harness seeds into the mobile config store.
//
export interface ISeedNewsItem {
    // Stable id used to track whether the item has been shown.
    id: string;

    // The toast message.
    message: string;

    // Optional toast colour variant.
    color?: string;
}

//
// A secret record the test harness seeds into the mobile config store.
//
export interface ISeedSecret {
    // The secret entry (name is the unique key; type is the category, e.g. 'encryption-key').
    entry: { name: string; type: string };

    // The secret value as a string.
    value: string;
}

//
// A database entry the test harness seeds into the mobile config store. Mirrors the subset of
// IDatabaseEntry the seeding needs; kept local so the driver has no dependency on the platform types.
//
export interface ISeedDatabaseEntry {
    // Display name (unique, case-insensitive).
    name: string;

    // Optional description.
    description?: string;

    // Database path (sandbox-relative on mobile).
    path: string;
}

//
// Transport abstraction over which the shared DOM test driver receives commands and emits
// log lines. Implemented by an Electron-IPC transport (desktop renderer) and a WebSocket
// transport (mobile WebView).
//
export interface ITestTransport {
    //
    // Registers the handler invoked for each incoming test command. The handler resolves with
    // the command's result value (returned to the caller for transports that reply, such as
    // get-value over the WebSocket); commands with no result resolve undefined.
    //
    onCommand(handler: (command: string, payload: ITestCommandPayload) => Promise<string | undefined>): void;

    //
    // Forwards a log line (level + message) to the host log file.
    //
    sendLog(level: string, message: string): void;
}

//
// Waits up to `timeoutMs` for the element with the given `data-id` (the `nth` one) to exist in the
// DOM, polling briefly. Test targets that render asynchronously (for example a database list item
// populated after its dialog opens) may not be present the instant the command arrives; without
// this a click fires before the element exists, finds nothing, and silently does nothing, which
// surfaces as a flaky failure. Resolves as soon as the element appears, or after the timeout if it
// never does; the caller then handles the found/not-found case as usual.
//
export async function waitForElement(dataId: string, nth: number, timeoutMs: number): Promise<void> {
    const intervalMs = 50;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const elements = document.querySelectorAll(`[data-id="${dataId}"]`);
        if (elements[nth]) {
            return;
        }
        await new Promise<void>((resolve) => {
            setTimeout(resolve, intervalMs);
        });
    }
}

//
// Clicks the element with the given `data-id`. When several elements share the id, `nth`
// selects which one (defaults to the first).
//
export function doClick(dataId: string, nth?: number): void {
    const elements = document.querySelectorAll(`[data-id="${dataId}"]`);
    const index = nth ?? 0;
    const element = elements[index] as HTMLElement | undefined;
    if (element) {
        console.log(`test-click: clicking element data-id="${dataId}" nth=${index}`);
        element.click();
    }
    else {
        console.warn(`test-click: element not found data-id="${dataId}" nth=${index}`);
    }
}

//
// Performs a short press (mousedown then mouseup) on the element with the given `data-id`,
// so components using a long-press gesture treat it as a normal short click.
//
export function doLongPressClick(dataId: string, nth?: number): void {
    const elements = document.querySelectorAll(`[data-id="${dataId}"]`);
    const index = nth ?? 0;
    const element = elements[index] as HTMLElement | undefined;
    if (!element) {
        console.warn(`test-long-press-click: element not found data-id="${dataId}" nth=${index}`);
        return;
    }
    console.log(`test-long-press-click: clicking element data-id="${dataId}" nth=${index}`);
    const rect = element.getBoundingClientRect();
    const clientX = rect.left + rect.width / 2;
    const clientY = rect.top + rect.height / 2;
    // Dispatch mousedown then mouseup so useLongPress treats this as a real short click.
    element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX, clientY }));
    element.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0, clientX, clientY }));
}

//
// Types text into the input nested under the element with the given `data-id`, using the
// native value setter so React's controlled inputs observe the change.
//
export function doType(dataId: string, text: string): void {
    const element = document.querySelector(`[data-id="${dataId}"] input`) as HTMLInputElement | null;
    if (element) {
        console.log(`test-type: typing into element data-id="${dataId}"`);
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
        if (nativeInputValueSetter) {
            nativeInputValueSetter.call(element, text);
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }
    else {
        console.warn(`test-type: element not found data-id="${dataId}"`);
    }
}

//
// Simulates a file drop of the given paths onto the element with the given `data-id`. The
// real file path is stashed on each File as `__testPath` so the drop handler can resolve it
// (the renderer cannot construct real File paths in test mode).
//
export function doDrop(dataId: string, paths: string[]): void {
    const element = document.querySelector(`[data-id="${dataId}"]`) as HTMLElement | null;
    if (!element) {
        console.warn(`test-drop: element not found data-id="${dataId}"`);
        return;
    }
    console.log(`test-drop: dropping ${paths.length} path(s) onto data-id="${dataId}"`);
    const dataTransfer = new DataTransfer();
    for (const filePath of paths) {
        const filename = filePath.split('/').pop() || filePath;
        const file = new File([], filename);
        (file as any).__testPath = filePath;
        dataTransfer.items.add(file);
    }
    const dropEvent = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer });
    element.dispatchEvent(dropEvent);
}

//
// Window event name used to stage picked file paths for the mobile native photo picker in tests.
//
export const TEST_PICK_FILES_EVENT = "photosphere-test:pick-files";

//
// Stages the given sandbox-relative paths as the result of the next native photo pick by dispatching
// a window event the mobile platform provider listens for. The smoke test calls this before clicking
// the "Import files" button, so the button's platform.pickFiles resolves with these paths instead of
// opening the (non-automatable) native picker dialog. Mirrors how doDrop injects paths on desktop.
//
export function doPickFiles(paths: string[]): void {
    console.log(`test-pick-files: staging ${paths.length} path(s) for the next picker`);
    window.dispatchEvent(new CustomEvent(TEST_PICK_FILES_EVENT, { detail: paths }));
}

//
// Reads the current value of the element with the given `data-id`, preferring its input
// value and falling back to its text content. Returns an empty string when not found.
//
export function getValue(dataId: string): string {
    const element = document.querySelector(`[data-id="${dataId}"]`) as HTMLElement | null;
    if (!element) {
        return '';
    }
    const inputValue = (element as HTMLInputElement).value;
    return inputValue || element.textContent || '';
}

//
// Navigates the app to the given route by updating the location hash (both desktop and
// mobile shells mount a HashRouter). The route is normalised to start with a slash.
//
export function doNavigate(page: string): void {
    const normalized = page.startsWith('/') ? page : `/${page}`;
    console.log(`test-navigate: navigating to ${normalized}`);
    window.location.hash = normalized;
}

//
// Triggers an application menu action by dispatching a window event. On desktop the menu is a
// native menu wired over IPC, so this is unused there; on mobile (which has no menu bar) the
// platform provider listens for this event and fires the same menu-action callbacks the app
// registers, exercising the real action handler.
//
export function doMenu(itemId: string): void {
    console.log(`test-menu: dispatching menu action "${itemId}"`);
    window.dispatchEvent(new CustomEvent(TEST_MENU_EVENT, { detail: itemId }));
}

//
// Requests opening a database by dispatching a window event. On mobile the platform provider
// listens for this event and fires the onDatabaseOpened callbacks the app registers, driving
// the real database-load path (which fails where mobile storage is not yet implemented).
//
export function doOpenDatabase(path: string): void {
    console.log(`test-open-database: opening database "${path}"`);
    window.dispatchEvent(new CustomEvent(TEST_OPEN_DATABASE_EVENT, { detail: path }));
}

//
// Window event name used to drive a menu action into the app.
//
export const TEST_MENU_EVENT = "photosphere-test:menu";

//
// Window event name used to drive opening a database into the app.
//
export const TEST_OPEN_DATABASE_EVENT = "photosphere-test:open-database";

//
// Window event name used to seed the mobile config store's databases list (test setup).
//
export const TEST_SEED_DATABASES_EVENT = "photosphere-test:seed-databases";

//
// Window event name used to seed the mobile config store's secrets list (test setup).
//
export const TEST_SEED_SECRETS_EVENT = "photosphere-test:seed-secrets";

//
// Window event name used to seed the mobile config store's recent-databases list (test setup).
//
export const TEST_SEED_RECENT_EVENT = "photosphere-test:seed-recent";

//
// Window event name used to seed the mobile config store's news items (test setup).
//
export const TEST_SEED_NEWS_EVENT = "photosphere-test:seed-news";

//
// Window event name used to clear the mobile config store (test setup).
//
export const TEST_RESET_CONFIG_EVENT = "photosphere-test:reset-config";

//
// Seeds news items by dispatching a window event the mobile platform provider listens for; the
// provider then shows the first unshown item as a toast. Mirrors the desktop news feed in tests.
//
export function doSeedNews(news: ISeedNewsItem[]): void {
    console.log(`test-seed-news: seeding ${news.length} news item(s)`);
    window.dispatchEvent(new CustomEvent(TEST_SEED_NEWS_EVENT, { detail: news }));
}

//
// Seeds the recent-databases list by dispatching a window event the mobile platform provider
// listens for. Used by smoke tests that need a pre-existing recent entry.
//
export function doSeedRecent(databases: ISeedDatabaseEntry[]): void {
    console.log(`test-seed-recent: seeding ${databases.length} recent database(s)`);
    window.dispatchEvent(new CustomEvent(TEST_SEED_RECENT_EVENT, { detail: databases }));
}

//
// Seeds the secrets list by dispatching a window event the mobile platform provider listens for.
// Used by smoke tests that need a pre-existing secret to edit/view (desktop seeds the vault instead).
//
export function doSeedSecrets(secrets: ISeedSecret[]): void {
    console.log(`test-seed-secrets: seeding ${secrets.length} secret(s)`);
    window.dispatchEvent(new CustomEvent(TEST_SEED_SECRETS_EVENT, { detail: secrets }));
}

//
// Seeds the configured-databases list by dispatching a window event the mobile platform provider
// listens for. Used by smoke tests to establish a known database list (the desktop equivalent is
// writing databases.toml). A no-op on shells without a listener.
//
export function doSeedDatabases(databases: ISeedDatabaseEntry[]): void {
    console.log(`test-seed-databases: seeding ${databases.length} database(s)`);
    window.dispatchEvent(new CustomEvent(TEST_SEED_DATABASES_EVENT, { detail: databases }));
}

//
// Clears the mobile config store (databases, recent databases, secrets) by dispatching a window
// event the mobile platform provider listens for. Used by smoke tests for a deterministic start.
//
export function doResetConfig(): void {
    console.log(`test-reset-config: clearing persisted config`);
    window.dispatchEvent(new CustomEvent(TEST_RESET_CONFIG_EVENT));
}

//
// Installs the shared DOM test driver onto the given transport. Each command received over
// the transport is dispatched to the matching DOM action; get-value returns the element's
// value, the rest resolve undefined. Unknown commands reject with a clear message so a
// shell that has not yet implemented a capability reports it rather than silently passing.
//
export function installTestDriver(transport: ITestTransport): void {
    transport.onCommand(async (command: string, payload: ITestCommandPayload): Promise<string | undefined> => {
        switch (command) {
            case 'click':
                await waitForElement(payload.dataId!, payload.nth ?? 0, 5000);
                doClick(payload.dataId!, payload.nth);
                return undefined;
            case 'long-press-click':
                doLongPressClick(payload.dataId!, payload.nth);
                return undefined;
            case 'type':
                doType(payload.dataId!, payload.text!);
                return undefined;
            case 'drop':
                doDrop(payload.dataId!, payload.paths!);
                return undefined;
            case 'pick-files':
                doPickFiles(payload.paths!);
                return undefined;
            case 'get-value':
                return getValue(payload.dataId!);
            case 'navigate':
                doNavigate(payload.page!);
                return undefined;
            case 'menu':
                doMenu(payload.itemId!);
                return undefined;
            case 'open-database':
                doOpenDatabase(payload.path!);
                return undefined;
            case 'seed-databases':
                doSeedDatabases(payload.databases!);
                return undefined;
            case 'seed-secrets':
                doSeedSecrets(payload.secrets!);
                return undefined;
            case 'seed-recent':
                doSeedRecent(payload.recent!);
                return undefined;
            case 'seed-news':
                doSeedNews(payload.news!);
                return undefined;
            case 'reset-config':
                doResetConfig();
                return undefined;
            case 'lan-share-roundtrip':
                return await runLanShareRoundtrip();
            default:
                throw new Error(`Test command not implemented on this platform: ${command}`);
        }
    });
}
