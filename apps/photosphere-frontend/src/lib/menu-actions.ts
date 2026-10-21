//
// How the page interprets the menu items the core hands it. The Photosphere menu is defined in Zig with Ziggy's menu types
// (packages-zig/photosphere-core/src/lib/menu.zig); the shell does the standard actions itself (quit, close-window, reload,
// toggle-devtools, toggle-fullscreen, the zoom commands and the editing commands) and the core sends every other item to the
// page as the app event {type: "menu", item}, where item is the item's name. Each name is a string, called an action here, and
// this file says what each one means, as a description of an effect the platform provider then carries out.
//

//
// The themes the Preferences menu can choose.
//
export type MenuTheme = "light" | "dark" | "system";

//
// The wiki page the Help item opens in the system browser.
//
export const HELP_URL = "https://github.com/ashleydavis/photosphere/wiki";

//
// Go to a route of the app.
//
export interface IMenuNavigateEffect {
    // Identifies this effect.
    kind: "navigate";

    // The route to go to, starting with a slash, such as "/gallery".
    page: string;
}

//
// Change the theme setting, which the core announces to the page with a theme-changed event.
//
export interface IMenuSetThemeEffect {
    // Identifies this effect.
    kind: "set-theme";

    // The theme to switch to.
    theme: MenuTheme;
}

//
// Show the folder that holds the log files in the system's file manager.
//
export interface IMenuOpenLogDirectoryEffect {
    // Identifies this effect.
    kind: "open-log-directory";
}

//
// Open a web address in the system browser.
//
export interface IMenuOpenUrlEffect {
    // Identifies this effect.
    kind: "open-url";

    // The address to open.
    url: string;
}

//
// Close the open database.
//
export interface IMenuCloseDatabaseEffect {
    // Identifies this effect.
    kind: "close-database";
}

//
// Hand the action to the subscribers of platform events, as {type: "menu-action", action}, for the app's own menu handler.
//
export interface IMenuPlatformEventEffect {
    // Identifies this effect.
    kind: "platform-event";

    // The action, passed on unchanged.
    action: string;
}

//
// What a menu action asks the page to do.
//
export type MenuEffect =
    | IMenuNavigateEffect
    | IMenuSetThemeEffect
    | IMenuOpenLogDirectoryEffect
    | IMenuOpenUrlEffect
    | IMenuCloseDatabaseEffect
    | IMenuPlatformEventEffect;

//
// The prefix of an action that goes to a route, such as "navigate:/gallery".
//
const navigatePrefix = "navigate:";

//
// The prefix of an action that chooses a theme, such as "theme:dark".
//
const themePrefix = "theme:";

//
// Gives a route its leading slash, the way the Electron app's navigate handler does.
//
export function normalizeRoute(page: string): string {
    return page.startsWith("/") ? page : `/${page}`;
}

//
// Works out what a menu action asks for. An action the page has no meaning of its own for is passed on as a platform event, which
// is how new-database, add-database, open-database, import-assets, open-configuration, report-bug and the rest reach the app. An
// action that claims a meaning and is malformed (a navigate with no route, a theme that does not exist) throws.
//
export function interpretMenuAction(action: string): MenuEffect {
    if (action.startsWith(navigatePrefix)) {
        const page = action.slice(navigatePrefix.length);
        if (page.length === 0) {
            throw new Error(`The menu action "${action}" names no route to navigate to.`);
        }
        return {
            kind: "navigate",
            page: normalizeRoute(page),
        };
    }
    if (action.startsWith(themePrefix)) {
        const theme = action.slice(themePrefix.length);
        if (theme !== "light" && theme !== "dark" && theme !== "system") {
            throw new Error(`The menu action "${action}" names a theme that is not light, dark or system.`);
        }
        return {
            kind: "set-theme",
            theme,
        };
    }
    switch (action) {
        case "about":
            return {
                kind: "navigate",
                page: "/about",
            };
        case "open-log-directory":
            return {
                kind: "open-log-directory",
            };
        case "help":
            return {
                kind: "open-url",
                url: HELP_URL,
            };
        case "close-database":
            return {
                kind: "close-database",
            };
        default:
            return {
                kind: "platform-event",
                action,
            };
    }
}

//
// The folder that holds a log file, from the file's path, which the core's get-log-details reply carries. Both kinds of path
// separator are understood because the core reports the path as the operating system writes it.
//
export function logDirectoryOf(logFilePath: string | null): string {
    if (logFilePath === null) {
        throw new Error("There is no log file to show the folder of, because file logging is not active.");
    }
    const lastSeparator = Math.max(logFilePath.lastIndexOf("/"), logFilePath.lastIndexOf("\\"));
    if (lastSeparator === -1) {
        throw new Error(`The log file path "${logFilePath}" has no folder.`);
    }
    if (lastSeparator === 0) {
        return logFilePath.slice(0, 1);
    }
    return logFilePath.slice(0, lastSeparator);
}
