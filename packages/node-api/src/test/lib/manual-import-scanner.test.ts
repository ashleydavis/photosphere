import * as fsSync from "fs";
import * as path from "path";
import { createTestTempDir } from "node-utils";
import { RandomUuidGenerator } from "utils";
import { ManualImportScanner } from "../../lib/manual-import-scanner";
import { IScannedImportFile } from "../../lib/import-scanner";

//
// Runs a scanner over the given paths and returns what it pushed.
//
async function scanFiles(paths: string[], sessionTempDir: string): Promise<IScannedImportFile[]> {
    const scanner = new ManualImportScanner(paths, { ignorePatterns: [/\.db/] }, sessionTempDir, new RandomUuidGenerator());
    const pushed: IScannedImportFile[] = [];
    await scanner.scan(
        async result => {
            pushed.push(result);
        },
        () => { /* nothing watching progress here. */ }
    );
    return pushed;
}

describe("ManualImportScanner", () => {

    let tempDir: string;
    let photosDir: string;

    beforeEach(() => {
        tempDir = createTestTempDir("manual-import-scanner");
        photosDir = path.join(tempDir, "photos");
        fsSync.mkdirSync(photosDir, { recursive: true });
    });

    //
    // Writes a file the scanner will recognise as media.
    //
    function writePhoto(fileName: string, contents: string): string {
        const filePath = path.join(photosDir, fileName);
        fsSync.writeFileSync(filePath, contents);
        return filePath;
    }

    test("pushes every file the scan finds and then returns", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");

        const pushed = await scanFiles([photosDir], tempDir);

        expect(pushed.map(file => path.basename(file.filePath)).sort()).toEqual(["a.jpg", "b.jpg"]);
    });

    test("returns without pushing anything when there is nothing to import", async () => {
        const pushed = await scanFiles([photosDir], tempDir);

        expect(pushed).toEqual([]);
    });

    test("returns without pushing anything when given no paths at all", async () => {
        const pushed = await scanFiles([], tempDir);

        expect(pushed).toEqual([]);
    });

    test("gives every file the size and modified time it actually has", async () => {
        const filePath = writePhoto("a.jpg", "one");
        const fileStat = fsSync.statSync(filePath);

        const pushed = await scanFiles([photosDir], tempDir);

        expect(pushed[0].fileStat.length).toBe(fileStat.size);
        expect(pushed[0].fileStat.lastModified.getTime()).toBe(fileStat.mtime.getTime());
    });

    test("identifies a file the user picked by nothing but its own path", async () => {
        // A file the user asked to import is a file: its path is what it is, and there is nothing
        // else to file its hash under. Only a photo library item needs an identity of its own.
        writePhoto("a.jpg", "one");

        const pushed = await scanFiles([photosDir], tempDir);

        expect(pushed[0].cacheIdentity).toBeUndefined();
    });

    test("has nothing to release, because it materialised nothing", async () => {
        const filePath = writePhoto("a.jpg", "one");
        const scanner = new ManualImportScanner([photosDir], { ignorePatterns: [/\.db/] }, tempDir, new RandomUuidGenerator());

        await scanner.release(filePath);

        // The file the user asked to import is still there. Releasing it must never mean deleting it.
        expect(fsSync.existsSync(filePath)).toBe(true);
    });
});
