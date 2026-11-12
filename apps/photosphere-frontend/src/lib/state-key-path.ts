//
// The state file's key path for each key the interface's state store uses. The declared keys have a path of their own; every other key is
// the interface's own working state, under `ui`, with the key encoded so a key holding a dot stays one key.
//

//
// The state file key path of an interface state key.
//
export function stateKeyPath(key: string): string {
    switch (key) {
        case "lastFolder":
            return "desktop.last_folder";
        case "lastDownloadFolder":
            return "desktop.last_download_folder";
        case "devToolsOpen":
            return "desktop.dev_tools_open";
        case "recentSearches":
            return "searches.recent";
        case "gallerySort":
            return "gallery.sort";
        case "galleryRowHeight":
            return "gallery.row_height";
        default:
            return `ui.${encodeKey(key)}`;
    }
}

//
// Percent-encodes a key so that it holds no dot: the percent sign first, then the dot. The replacement is reversible, so two different
// keys never map to one path.
//
function encodeKey(key: string): string {
    return key.replace(/%/g, "%25").replace(/\./g, "%2E");
}
