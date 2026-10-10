//
// Photosphere's desktop menu: the menu bar, written once. Ziggy's shells draw it natively on
// every desktop platform and never on a phone.
//
// An action the shells know does what it says in the shell: quit, close-window, reload, toggle-devtools, toggle-fullscreen, zoom-in,
// zoom-out, zoom-reset, undo, redo, cut, copy, paste and select-all. Every other action is Photosphere's and the core hands it to the
// page as a menu-action event. The page reads an action like this:
//
//  - `navigate:<route>` goes to the page at the route.
//  - `theme:<light|dark|system>` saves the theme and tells the page.
//  - `open-log-directory` shows the folder the log files are in.
//  - `help` opens the wiki in the system browser.
//  - Anything else (new-database, add-database, open-database, import-assets, close-database, open-configuration and report-bug) is
//    the platform event of that name.
//
// What Ziggy's menus force:
//  - The menu is written once, so it is not built again when a database is opened or closed, and Import Assets and Close Database
//    are always in the File menu. The page does nothing for either action while no database is open.
//  - The theme items are plain items, not radio buttons that show the saved theme.
//  - There is no Window menu: Ziggy's shells have no action to minimise or zoom the window. Close Window is in the File menu.
//  - The Edit menu is Ziggy's, because MacOS needs it for the editing shortcuts to reach the page.
//  - A Developer menu holds the stories browser and the developer tools.
//

pub const menu_json =
    \\[
    \\  {"label": "File", "items": [
    \\    {"label": "New Database...", "action": "new-database", "accelerator": "CmdOrCtrl+N"},
    \\    {"label": "Add Database...", "action": "add-database"},
    \\    {"label": "Open Database...", "action": "open-database", "accelerator": "CmdOrCtrl+O"},
    \\    {"separator": true},
    \\    {"label": "Import Assets...", "action": "import-assets", "accelerator": "CmdOrCtrl+I"},
    \\    {"separator": true},
    \\    {"label": "Close Database", "action": "close-database"},
    \\    {"separator": true},
    \\    {"label": "Close Window", "action": "close-window", "accelerator": "CmdOrCtrl+W"},
    \\    {"label": "Exit", "action": "quit", "accelerator": "CmdOrCtrl+Q"}
    \\  ]},
    \\  {"label": "Edit", "items": [
    \\    {"label": "Undo", "action": "undo", "accelerator": "CmdOrCtrl+Z"},
    \\    {"label": "Redo", "action": "redo", "accelerator": "CmdOrCtrl+Shift+Z"},
    \\    {"separator": true},
    \\    {"label": "Cut", "action": "cut", "accelerator": "CmdOrCtrl+X"},
    \\    {"label": "Copy", "action": "copy", "accelerator": "CmdOrCtrl+C"},
    \\    {"label": "Paste", "action": "paste", "accelerator": "CmdOrCtrl+V"},
    \\    {"label": "Select All", "action": "select-all", "accelerator": "CmdOrCtrl+A"}
    \\  ]},
    \\  {"label": "View", "items": [
    \\    {"label": "Gallery", "action": "navigate:/gallery"},
    \\    {"label": "Map", "action": "navigate:/map"},
    \\    {"label": "Import", "action": "navigate:/import"},
    \\    {"label": "Summary", "action": "navigate:/database-summary"},
    \\    {"label": "News", "action": "navigate:/news"},
    \\    {"label": "About", "action": "navigate:/about"},
    \\    {"separator": true},
    \\    {"label": "Actual Size", "action": "zoom-reset", "accelerator": "CmdOrCtrl+0"},
    \\    {"label": "Zoom In", "action": "zoom-in", "accelerator": "CmdOrCtrl+Plus"},
    \\    {"label": "Zoom Out", "action": "zoom-out", "accelerator": "CmdOrCtrl+Minus"},
    \\    {"separator": true},
    \\    {"label": "Toggle Fullscreen", "action": "toggle-fullscreen", "accelerator": "F11"}
    \\  ]},
    \\  {"label": "Preferences", "items": [
    \\    {"label": "Theme", "items": [
    \\      {"label": "Light", "action": "theme:light"},
    \\      {"label": "Dark", "action": "theme:dark"},
    \\      {"label": "System", "action": "theme:system"}
    \\    ]},
    \\    {"separator": true},
    \\    {"label": "Manage Databases", "action": "navigate:/databases"},
    \\    {"label": "Manage Secrets", "action": "navigate:/secrets"},
    \\    {"separator": true},
    \\    {"label": "Configuration...", "action": "open-configuration"}
    \\  ]},
    \\  {"label": "Developer", "items": [
    \\    {"label": "Stories", "action": "navigate:/stories"},
    \\    {"separator": true},
    \\    {"label": "Reload", "action": "reload", "accelerator": "CmdOrCtrl+R"},
    \\    {"label": "Toggle Developer Tools", "action": "toggle-devtools", "accelerator": "CmdOrCtrl+Shift+I"}
    \\  ]},
    \\  {"label": "Help", "items": [
    \\    {"label": "About Photosphere", "action": "navigate:/about"},
    \\    {"separator": true},
    \\    {"label": "Photosphere Help", "action": "help"},
    \\    {"separator": true},
    \\    {"label": "Open Log Directory", "action": "open-log-directory"},
    \\    {"separator": true},
    \\    {"label": "Report Bug...", "action": "report-bug"}
    \\  ]}
    \\]
;
