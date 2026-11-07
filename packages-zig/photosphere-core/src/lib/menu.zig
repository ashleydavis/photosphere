//
// Photosphere's desktop menu: the menu bar, written once. Ziggy's native apps draw it natively on every desktop platform and never
// on a phone.
//
// Each item says what it runs. A `.standard` item is an action the native app does itself: quit, close-window, reload, toggle-devtools,
// toggle-fullscreen, zoom-in, zoom-out, zoom-reset, undo, redo, cut, copy, paste and select-all. Every other item is Photosphere's and
// runs `.ui`, except Open Database, which runs the Ziggy action open-database (see actions.zig), whose handler `main.tsx`
// registers. For a `.ui` item the core sends the page the app event {"type": "menu", "item": "<name>"}. The page reads the item's
// `.name` like this:
//
//  - `navigate:<route>` goes to the page at the route.
//  - `about` goes to the About page. The Help menu's About item has this name because two items cannot share `navigate:/about`.
//  - `theme:<light|dark|system>` saves the theme and tells the page.
//  - `open-log-directory` shows the folder the log files are in.
//  - `help` opens the wiki in the system browser.
//  - Anything else (new-database, add-database, import-assets, close-database, open-configuration and report-bug) is
//    the platform event of that name.
//
// What Ziggy's menus force:
//  - The menu is written once, so it is not built again when a database is opened or closed, and Import Assets and Close Database
//    are always in the File menu. The page does nothing for either item while no database is open.
//  - The theme items are plain items, not radio buttons that show the saved theme.
//  - There is no Window menu: Ziggy's native apps have no action to minimise or zoom the window. Close Window is in the File menu.
//  - The Edit menu is Ziggy's, because MacOS needs it for the editing shortcuts to reach the page.
//  - A Developer menu holds the stories browser and the developer tools.
//

const ziggy = @import("ziggy");

// The menu the Photosphere App passes to ziggy.core.App as `.menu`.
//
pub const menu: []const ziggy.menu.Menu = &.{
    .{
        .label = "File",
        .items = &.{
            .{
                .label = "New Database...",
                .name = "new-database",
                .shortcut = "CmdOrCtrl+N",
                .run = .ui,
            },
            .{
                .label = "Add Database...",
                .name = "add-database",
                .run = .ui,
            },
            .{
                .run = .{
                    .action = "open-database",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Import Assets...",
                .name = "import-assets",
                .shortcut = "CmdOrCtrl+I",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Close Database",
                .name = "close-database",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Close Window",
                .shortcut = "CmdOrCtrl+W",
                .run = .{
                    .standard = .@"close-window",
                },
            },
            .{
                .label = "Exit",
                .shortcut = "CmdOrCtrl+Q",
                .run = .{
                    .standard = .quit,
                },
            },
        },
    },
    .{
        .label = "Edit",
        .items = &.{
            .{
                .label = "Undo",
                .shortcut = "CmdOrCtrl+Z",
                .run = .{
                    .standard = .undo,
                },
            },
            .{
                .label = "Redo",
                .shortcut = "CmdOrCtrl+Shift+Z",
                .run = .{
                    .standard = .redo,
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Cut",
                .shortcut = "CmdOrCtrl+X",
                .run = .{
                    .standard = .cut,
                },
            },
            .{
                .label = "Copy",
                .shortcut = "CmdOrCtrl+C",
                .run = .{
                    .standard = .copy,
                },
            },
            .{
                .label = "Paste",
                .shortcut = "CmdOrCtrl+V",
                .run = .{
                    .standard = .paste,
                },
            },
            .{
                .label = "Select All",
                .shortcut = "CmdOrCtrl+A",
                .run = .{
                    .standard = .@"select-all",
                },
            },
        },
    },
    .{
        .label = "View",
        .items = &.{
            .{
                .label = "Gallery",
                .name = "navigate:/gallery",
                .run = .ui,
            },
            .{
                .label = "Map",
                .name = "navigate:/map",
                .run = .ui,
            },
            .{
                .label = "Import",
                .name = "navigate:/import",
                .run = .ui,
            },
            .{
                .label = "Summary",
                .name = "navigate:/database-summary",
                .run = .ui,
            },
            .{
                .label = "News",
                .name = "navigate:/news",
                .run = .ui,
            },
            .{
                .label = "About",
                .name = "navigate:/about",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Actual Size",
                .shortcut = "CmdOrCtrl+0",
                .run = .{
                    .standard = .@"zoom-reset",
                },
            },
            .{
                .label = "Zoom In",
                .shortcut = "CmdOrCtrl+Plus",
                .run = .{
                    .standard = .@"zoom-in",
                },
            },
            .{
                .label = "Zoom Out",
                .shortcut = "CmdOrCtrl+Minus",
                .run = .{
                    .standard = .@"zoom-out",
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Toggle Fullscreen",
                .shortcut = "F11",
                .run = .{
                    .standard = .@"toggle-fullscreen",
                },
            },
        },
    },
    .{
        .label = "Preferences",
        .items = &.{
            .{
                .label = "Theme",
                .items = &.{
                    .{
                        .label = "Light",
                        .name = "theme:light",
                        .run = .ui,
                    },
                    .{
                        .label = "Dark",
                        .name = "theme:dark",
                        .run = .ui,
                    },
                    .{
                        .label = "System",
                        .name = "theme:system",
                        .run = .ui,
                    },
                },
            },
            ziggy.menu.separator,
            .{
                .label = "Manage Databases",
                .name = "navigate:/databases",
                .run = .ui,
            },
            .{
                .label = "Manage Secrets",
                .name = "navigate:/secrets",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Configuration...",
                .name = "open-configuration",
                .run = .ui,
            },
        },
    },
    .{
        .label = "Developer",
        .items = &.{
            .{
                .label = "Stories",
                .name = "navigate:/stories",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Reload",
                .shortcut = "CmdOrCtrl+R",
                .run = .{
                    .standard = .reload,
                },
            },
            .{
                .label = "Toggle Developer Tools",
                .shortcut = "CmdOrCtrl+Shift+I",
                .run = .{
                    .standard = .@"toggle-devtools",
                },
            },
        },
    },
    .{
        .label = "Help",
        .items = &.{
            .{
                .label = "About Photosphere",
                .name = "about",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Photosphere Help",
                .name = "help",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Open Log Directory",
                .name = "open-log-directory",
                .run = .ui,
            },
            ziggy.menu.separator,
            .{
                .label = "Report Bug...",
                .name = "report-bug",
                .run = .ui,
            },
        },
    },
};
