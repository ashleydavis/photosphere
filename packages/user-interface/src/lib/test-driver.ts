//
// Shared DOM test driver.
//
// In test mode the app is driven by smoke-test scripts that issue commands ("click",
// "type", ...) targeting elements by their `data-id` attribute. The same DOM-action logic
// is used by every shell (Electron desktop renderer, Android/iOS WebView). The transport
// that carries commands into the driver differs per shell (Electron IPC vs WebSocket), so
// the driver is parameterised by an ITestTransport.
//

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

    // News items to seed into the mobile config store (seed-news command).
    news?: ISeedNewsItem[];

    // A localStorage key to read back (get-storage command). Used by smoke tests to assert that a
    // value is or is not present in WebView localStorage (for example that no plaintext secret lingers).
    storageKey?: string;

    // Outcome to stage for the next mobile asset export (stage-export command).
    exportOutcome?: "shared" | "cancelled";

    // Result to stage for the next mobile pickFolder name prompt: a path, or null for cancel
    // (stage-pick-folder command).
    folderResult?: string | null;
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
// Reports whether an element is visible to a user, so the driver only ever acts on what is on
// screen. It walks ancestors rather than trusting the element's own style: `visibility` is
// inherited (a child of a hidden container computes to hidden already) but `display` is not (a child
// of a `display:none` parent still computes its own display), so both have to be checked up the tree.
//
// This matters on mobile because ResponsiveDialog renders a Joy Drawer, and a closed Drawer does not
// unmount: it stays in the DOM with `visibility:hidden` so it can animate. Several dialogs are also
// mounted from more than one place, so a `data-id` inside one can match several elements at once,
// all but one of them in a closed (hidden) drawer. querySelector returns the first in DOM order,
// which is whichever mounted first, not the one on screen. That is how the create-database test
// typed into an invisible form and left the visible one empty, disabling its Create button.
//
// Only visibility and display are checked, never layout/bounding boxes: jsdom (where the unit tests
// run) has no layout, so measuring one would report every element as invisible there.
//
export function isElementVisible(element: Element): boolean {
    let current: Element | null = element;
    while (current) {
        const style = window.getComputedStyle(current);
        if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') {
            return false;
        }
        current = current.parentElement;
    }
    return true;
}

//
// The visible elements carrying the given `data-id`, in DOM order.
//
function visibleElements(dataId: string): HTMLElement[] {
    return (Array.from(document.querySelectorAll(`[data-id="${dataId}"]`)) as HTMLElement[]).filter(isElementVisible);
}

//
// The nth visible element carrying the given `data-id`, or undefined.
//
function findElement(dataId: string, nth: number): HTMLElement | undefined {
    return visibleElements(dataId)[nth];
}

//
// The input nested under the first visible element carrying the given `data-id`, or undefined. Joy's
// Input puts the `data-id` on its wrapper and the real input inside it, so the action targets a node
// the `data-id` lookup alone does not reach.
//
function findNestedInput(dataId: string): HTMLInputElement | HTMLTextAreaElement | undefined {
    for (const wrapper of visibleElements(dataId)) {
        const input = wrapper.querySelector('input, textarea');
        if (input && isElementVisible(input)) {
            return input as HTMLInputElement | HTMLTextAreaElement;
        }
    }
    return undefined;
}

//
// The clock the driver measures deadlines against and waits on. It exists so a unit test can drive
// the driver's waits deliberately instead of racing the machine: waitForElement polls against a
// deadline, so a test that schedules a late render and then waits for it fails whenever the machine
// stalls past the deadline, which it did under the full parallel suite. Replacing the global timers
// with jest fake timers would fix that too, but fake timers are installed for the whole file and
// break every later test that needs real time, so the clock is swapped here instead.
//
export interface ITestDriverClock {
    // The current time in milliseconds, used to work out when a poll has run out of time.
    now(): number;

    // Resolves once the given number of milliseconds have passed.
    sleep(milliseconds: number): Promise<void>;
}

//
// Wall-clock time and real timers. This is what the app always runs with; only tests replace it.
//
export const realTestDriverClock: ITestDriverClock = {
    now(): number {
        return Date.now();
    },

    sleep(milliseconds: number): Promise<void> {
        return new Promise<void>((resolve) => {
            setTimeout(resolve, milliseconds);
        });
    },
};

//
// The clock currently in use. Module state rather than a parameter so no call site has to thread a
// clock through; setTestDriverClock is the only thing that changes it.
//
let currentTestDriverClock: ITestDriverClock = realTestDriverClock;

//
// Replaces the clock the driver measures and waits on, and returns nothing. Only tests call this,
// and a test that calls it must put realTestDriverClock back afterwards, or the driver keeps waiting
// on a clock that nothing advances.
//
export function setTestDriverClock(clock: ITestDriverClock): void {
    currentTestDriverClock = clock;
}

//
// Waits up to `timeoutMs` for the `nth` VISIBLE element with the given `data-id` to exist, polling
// briefly. Test targets that render asynchronously (for example a database list item populated after
// its dialog opens) may not be present the instant the command arrives; without this a click fires
// before the element exists, finds nothing, and silently does nothing, which surfaces as a flaky
// failure. Resolves as soon as a visible match appears, or after the timeout if it never does.
//
export async function waitForElement(dataId: string, nth: number, timeoutMs: number): Promise<void> {
    const intervalMs = 50;
    const deadline = currentTestDriverClock.now() + timeoutMs;
    while (currentTestDriverClock.now() < deadline) {
        if (findElement(dataId, nth)) {
            return;
        }
        await currentTestDriverClock.sleep(intervalMs);
    }
}

//
// Selects a radio or checkbox input, the two controls that only change state when the input itself
// is clicked.
//
const TOGGLE_INPUT_SELECTOR = 'input[type="radio"], input[type="checkbox"]';

//
// Reports whether an element is a radio or checkbox input.
//
export function isToggleInput(element: Element): boolean {
    return element.matches(TOGGLE_INPUT_SELECTOR);
}

//
// The element a click should actually land on. Joy puts the `data-id` on a wrapper `<span>` and the
// real form control inside it, so clicking a Joy `<Radio>` by its `data-id` clicks the wrapper and
// selects nothing: the test then asserts against a screen that never changed and passes.
//
// The redirect is deliberately conservative, because returning the element unchanged is always the
// safe answer and behaves exactly as the driver does today. An element that is already clickable in
// its own right (a button, a link, a bare toggle input) is never redirected, and a wrapper is only
// redirected when it contains exactly one toggle input, so anything ambiguous is left alone.
//
export function clickTarget(element: HTMLElement): HTMLElement {
    if (element.matches(`button, a, ${TOGGLE_INPUT_SELECTOR}`)) {
        return element;
    }
    const toggles = element.querySelectorAll(TOGGLE_INPUT_SELECTOR);
    if (toggles.length === 1) {
        return toggles[0] as HTMLElement;
    }
    return element;
}

//
// Clicks the element with the given `data-id`. When several elements share the id, `nth`
// selects which one (defaults to the first).
//
export function doClick(dataId: string, nth?: number): void {
    const index = nth ?? 0;
    const element = findElement(dataId, index);
    if (element) {
        const target = clickTarget(element);
        // Report a redirect, so a future failure shows what was actually clicked rather than what was asked for.
        const redirect = target === element ? '' : ` (redirected to nested <${target.tagName.toLowerCase()} type="${(target as HTMLInputElement).type}">)`;
        console.log(`test-click: clicking element data-id="${dataId}" nth=${index}${redirect}`);
        target.click();
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
    const index = nth ?? 0;
    const element = findElement(dataId, index);
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

// How long a real long press holds the button down for. useLongPress starts its own timer on
// mousedown and fires onLongPress when it elapses; the gallery leaves that delay unset (so it is
// effectively immediate), but holding well past any reasonable delay keeps this robust.
const LONG_PRESS_HOLD_MS = 700;

//
// Performs a real long press on the element with the given `data-id`: presses, holds past the
// gesture's delay so useLongPress fires onLongPress, then releases.
//
// This is not doLongPressClick, which releases immediately so a long-press component treats it as a
// short click. It is the opposite gesture, and it is the only way to drive selection mode on a
// phone: the gallery reveals its selection checkboxes only once a long press has turned selecting on
// (gallery-image.tsx), or on hover, which a phone does not have.
//
export async function doLongPress(dataId: string, nth?: number): Promise<void> {
    const index = nth ?? 0;
    const element = findElement(dataId, index);
    if (!element) {
        console.warn(`test-long-press: element not found data-id="${dataId}" nth=${index}`);
        return;
    }
    console.log(`test-long-press: long pressing element data-id="${dataId}" nth=${index}`);
    const rect = element.getBoundingClientRect();
    const clientX = rect.left + rect.width / 2;
    const clientY = rect.top + rect.height / 2;
    element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX, clientY }));
    await currentTestDriverClock.sleep(LONG_PRESS_HOLD_MS);
    element.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0, clientX, clientY }));
}

//
// Types text into the input nested under the element with the given `data-id`, using the
// native value setter so React's controlled inputs observe the change.
//
export function doType(dataId: string, text: string): void {
    const element = findNestedInput(dataId);
    if (element) {
        console.log(`test-type: typing into element data-id="${dataId}"`);
        // A masked PEM field is a <textarea>, whose value setter lives on HTMLTextAreaElement, not
        // HTMLInputElement; pick the prototype matching the element so React observes the change.
        const valueSetterPrototype = element instanceof HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(valueSetterPrototype, 'value')?.set;
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
    const element = findElement(dataId, 0);
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
// Window event name used to stage the outcome of the next mobile asset export (share sheet) in tests.
//
export const TEST_STAGE_EXPORT_EVENT = "photosphere-test:stage-export";

//
// Stages the outcome of the next asset export by dispatching a window event the mobile platform
// provider listens for, so the export share sheet resolves with this outcome (a completed "shared"
// or a "cancelled") without presenting the non-automatable native sheet. The smoke test calls this
// before triggering a download to drive the success and cancel paths.
//
export function doStageExport(outcome: "shared" | "cancelled"): void {
    console.log(`test-stage-export: staging export outcome "${outcome}"`);
    window.dispatchEvent(new CustomEvent(TEST_STAGE_EXPORT_EVENT, { detail: outcome }));
}

//
// Window event name used to stage the result of the next mobile pickFolder name prompt in tests.
//
export const TEST_STAGE_PICK_FOLDER_EVENT = "photosphere-test:stage-pick-folder";

//
// Stages the result of the next pickFolder "Browse" name prompt by dispatching a window event the
// mobile platform provider listens for: a sandbox-relative path is returned as the picked folder,
// and null simulates the user cancelling. The smoke test calls this before clicking a Browse button.
//
export function doStagePickFolder(result: string | null): void {
    console.log(`test-stage-pick-folder: staging pick-folder result "${result ?? "(cancel)"}"`);
    window.dispatchEvent(new CustomEvent(TEST_STAGE_PICK_FOLDER_EVENT, { detail: result }));
}

//
// Reads the current value of the element with the given `data-id`: its own value when it is a form
// control, otherwise its text, otherwise the value of an input nested inside it. Returns an empty
// string when not found.
//
// Text comes ahead of the nested input on purpose. A container that happens to hold a Joy `<Switch>`
// contains a hidden checkbox whose value is the string "on" by default, and "on" is truthy, so
// reading the nested input first reported "on" for any panel or row with a switch in it. A test
// waiting for that container's text then waited for something that could never be returned.
//
export function getValue(dataId: string): string {
    // The visible one: on mobile a closed drawer keeps its content in the DOM, so reading the first
    // raw match could report a stale value from a dialog that is not on screen.
    const element = findElement(dataId, 0);
    if (!element) {
        return '';
    }
    // The element is itself a form control, so its own value is the unambiguous answer.
    if (element.matches('input, textarea, select')) {
        return (element as HTMLInputElement).value;
    }
    // A container's text is what a test asking for its value means. Emptiness is judged on the
    // trimmed text so the whitespace between a wrapper's tags does not count as a value, but the
    // text is returned as-is to keep what existing tests already read from it.
    const textContent = element.textContent || '';
    if (textContent.trim()) {
        return textContent;
    }
    // Joy's Input carries the data-id on its wrapper, which holds no text of its own, and the value
    // on the input nested inside it.
    const nestedInput = element.querySelector('input, textarea');
    if (nestedInput) {
        return (nestedInput as HTMLInputElement).value;
    }
    return '';
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
// Window event name used to seed the mobile config store's news items (test setup).
//
// This is the one piece of state a mobile smoke test cannot set up from outside the app: the news
// feed lives in WebView localStorage, which no host-side tool can write. Everything else a test
// needs (the database list, the recents, the secrets) is established by the harness before launch,
// by writing the app's databases.toml and clearing its stored data (see apps/smoke-tests/lib).
//
export const TEST_SEED_NEWS_EVENT = "photosphere-test:seed-news";

//
// Window event name used to signal that the database was edited, scheduling a background sync.
//
export const TEST_NOTIFY_DATABASE_EDITED_EVENT = "photosphere-test:notify-database-edited";

//
// Signals that the database was edited by dispatching a window event the mobile platform provider
// listens for; the provider asks the sync scheduler to schedule its debounced background sync. This is
// the test-side equivalent of an edit made through the UI.
//
export function doNotifyDatabaseEdited(): void {
    console.log(`test-notify-database-edited: scheduling a background sync`);
    window.dispatchEvent(new Event(TEST_NOTIFY_DATABASE_EDITED_EVENT));
}

//
// Seeds news items by dispatching a window event the mobile platform provider listens for; the
// provider then shows the first unshown item as a toast. Mirrors the desktop news feed in tests.
//
export function doSeedNews(news: ISeedNewsItem[]): void {
    console.log(`test-seed-news: seeding ${news.length} news item(s)`);
    window.dispatchEvent(new CustomEvent(TEST_SEED_NEWS_EVENT, { detail: news }));
}

//
// Advances the stories cycle to the next story by dispatching the "cycle-advance" event the
// stories page listens for. The Electron shell dispatches that event straight into the renderer;
// on mobile it arrives here as a test command, so the stories runner drives every platform the
// same way. The stories runner calls this once it has captured a screenshot of the current story,
// so the cycle proceeds as fast as capture allows instead of waiting out the dwell timer. A no-op
// when the stories cycle is not mounted.
//
export function doCycleAdvance(): void {
    console.log(`test-cycle-advance: advancing the stories cycle`);
    window.dispatchEvent(new Event("cycle-advance"));
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
            case 'long-press':
                await waitForElement(payload.dataId!, payload.nth ?? 0, 5000);
                await doLongPress(payload.dataId!, payload.nth);
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
            case 'stage-export':
                doStageExport(payload.exportOutcome!);
                return undefined;
            case 'stage-pick-folder':
                doStagePickFolder(payload.folderResult ?? null);
                return undefined;
            case 'get-value':
                return getValue(payload.dataId!);
            case 'get-storage':
                return window.localStorage.getItem(payload.storageKey!) ?? '';
            case 'navigate':
                doNavigate(payload.page!);
                return undefined;
            case 'menu':
                doMenu(payload.itemId!);
                return undefined;
            case 'open-database':
                doOpenDatabase(payload.path!);
                return undefined;
            case 'seed-news':
                doSeedNews(payload.news!);
                return undefined;
            case 'notify-database-edited':
                doNotifyDatabaseEdited();
                return undefined;
            case 'cycle-advance':
                doCycleAdvance();
                return undefined;
            default:
                throw new Error(`Test command not implemented on this platform: ${command}`);
        }
    });
}
