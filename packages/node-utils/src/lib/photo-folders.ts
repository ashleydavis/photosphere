import * as fsSync from 'fs';
import * as os from 'os';
import * as path from 'path';

//
// The operating system's photo locations, for use as the starting source list for automatic
// import. The candidate list is separated from the existence check so the per-platform decision can
// be unit tested on any machine, rather than only on the platform it describes.
//

//
// Where the XDG user directories file lives, relative to the user's home directory. Linux desktops
// record the user's chosen Pictures folder here, which is often not "Pictures" in an English
// install and is frequently not "Pictures" at all in a translated one.
//
const XDG_USER_DIRS_PATH = '.config/user-dirs.dirs';

//
// Pulls the pictures directory out of the contents of an XDG user-dirs file, or returns undefined
// when the file does not name one. The file is shell-like: lines of KEY="value", where the value
// usually starts with $HOME, and lines starting with # are comments.
//
export function parseXdgPicturesDir(fileContents: string, homeDir: string): string | undefined {
    for (const rawLine of fileContents.split('\n')) {
        const line = rawLine.trim();
        if (line.length === 0 || line.startsWith('#')) {
            continue;
        }

        const match = /^XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$/.exec(line);
        if (!match) {
            continue;
        }

        const value = match[1];
        if (value.length === 0) {
            return undefined;
        }

        if (value === '$HOME') {
            return homeDir;
        }

        if (value.startsWith('$HOME/')) {
            return path.join(homeDir, value.slice('$HOME/'.length));
        }

        return value;
    }

    return undefined;
}

//
// Reads the user's XDG pictures directory, or returns undefined when there is no XDG user-dirs file
// or it does not name one. Never throws: a missing or unreadable file simply means "not configured".
//
export function readXdgPicturesDir(homeDir: string): string | undefined {
    const userDirsPath = path.join(homeDir, XDG_USER_DIRS_PATH);
    let fileContents: string;
    try {
        fileContents = fsSync.readFileSync(userDirsPath, 'utf8');
    }
    catch {
        return undefined;
    }

    return parseXdgPicturesDir(fileContents, homeDir);
}

//
// The photo locations an operating system is expected to have, before checking which of them are
// actually present on this machine. Duplicates are removed, so a Linux machine whose XDG pictures
// directory is the ordinary "Pictures" folder yields one entry rather than two.
//
export function getPhotoFolderCandidates(platform: NodeJS.Platform, homeDir: string, xdgPicturesDir: string | undefined): string[] {
    const candidates: string[] = [];

    if (platform === 'win32') {
        const picturesDir = path.join(homeDir, 'Pictures');
        candidates.push(picturesDir);
        candidates.push(path.join(picturesDir, 'Camera Roll'));
    }
    else if (platform === 'darwin') {
        candidates.push(path.join(homeDir, 'Pictures'));
    }
    else {
        if (xdgPicturesDir) {
            candidates.push(xdgPicturesDir);
        }
        else {
            candidates.push(path.join(homeDir, 'Pictures'));
        }
    }

    const seen = new Set<string>();
    const unique: string[] = [];
    for (const candidate of candidates) {
        if (!seen.has(candidate)) {
            seen.add(candidate);
            unique.push(candidate);
        }
    }
    return unique;
}

//
// Keeps only the candidates that exist on disk as directories. Never throws: a path that cannot be
// stat'ed at all is treated the same as one that is not there.
//
export function filterExistingFolders(candidates: string[]): string[] {
    const existing: string[] = [];
    for (const candidate of candidates) {
        try {
            if (fsSync.statSync(candidate).isDirectory()) {
                existing.push(candidate);
            }
        }
        catch {
            // Not there, or not readable. Either way it is not a photo folder we can watch.
        }
    }
    return existing;
}

//
// The operating system's photo locations that exist on this machine. Returns an empty list rather
// than throwing when none of them are present.
//
export function getDefaultPhotoFolders(): string[] {
    const homeDir = os.homedir();
    const xdgPicturesDir = process.platform === 'win32' || process.platform === 'darwin'
        ? undefined
        : readXdgPicturesDir(homeDir);
    return filterExistingFolders(getPhotoFolderCandidates(process.platform, homeDir, xdgPicturesDir));
}
