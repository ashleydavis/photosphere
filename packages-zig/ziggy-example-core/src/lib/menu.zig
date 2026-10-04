//
// The example's desktop menu. Ziggy's shells draw it natively on every desktop platform and never on a phone.
//
// An action the shells know does what it says in the shell: quit, reload, toggle-devtools, toggle-fullscreen, zoom-in,
// zoom-out, zoom-reset, undo, redo, cut, copy, paste and select-all. Every other action is the app's own, and the core hands it
// to the page as a menu-action event. See "Menus" in the architecture document.
//
pub const menu_json =
    \\[
    \\  {"label": "File", "items": [
    \\    {"label": "Quit", "action": "quit", "accelerator": "CmdOrCtrl+Q"}
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
    \\    {"label": "Reload", "action": "reload", "accelerator": "CmdOrCtrl+R"},
    \\    {"separator": true},
    \\    {"label": "Zoom In", "action": "zoom-in", "accelerator": "CmdOrCtrl+Plus"},
    \\    {"label": "Zoom Out", "action": "zoom-out", "accelerator": "CmdOrCtrl+Minus"},
    \\    {"label": "Actual Size", "action": "zoom-reset", "accelerator": "CmdOrCtrl+0"},
    \\    {"separator": true},
    \\    {"label": "Toggle Full Screen", "action": "toggle-fullscreen", "accelerator": "F11"},
    \\    {"separator": true},
    \\    {"label": "Toggle Developer Tools", "action": "toggle-devtools", "accelerator": "CmdOrCtrl+Shift+I"}
    \\  ]},
    \\  {"label": "Example", "items": [
    \\    {"label": "Start Short Task", "action": "start-short", "accelerator": "CmdOrCtrl+9"},
    \\    {"label": "Start Long Task", "action": "start-long", "accelerator": "CmdOrCtrl+2"},
    \\    {"label": "Start Three Long Tasks", "action": "start-many", "accelerator": "CmdOrCtrl+3"},
    \\    {"separator": true},
    \\    {"label": "Cancel Long Task", "action": "cancel-long", "accelerator": "CmdOrCtrl+4"}
    \\  ]},
    \\  {"label": "Help", "items": [
    \\    {"label": "About Ziggy Example", "action": "about"}
    \\  ]}
    \\]
;
