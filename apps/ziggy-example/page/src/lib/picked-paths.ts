//
// What the page shows after a file or folder picker. The pickers reply as the Electron app's do: the paths chosen, or null
// (Electron's undefined) when the user cancelled.
//

//
// Formats a picker's reply for display: one line per path chosen, or a line saying nothing was chosen.
//
export function formatPicked(title: string, result: string | string[] | null): string {
    if (result === null) {
        return `${title}: cancelled, nothing was chosen`;
    }
    const paths = Array.isArray(result) ? result : [result];
    return [`${title}: ${paths.length === 1 ? "1 path" : `${paths.length} paths`}`, ...paths.map(path => `  ${path}`)].join("\n");
}
