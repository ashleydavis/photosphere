import * as crypto from "crypto";
import { createTestTempDir } from "node-utils";
import { forgetSharedHashCaches, HashCache, loadSharedHashCache } from "../../lib/hash-cache";

//
// Covers the read-only hash cache that every file hashed in one engine shares, and the one thing it
// has to get right: it must not go on answering from a copy of a cache that has since been written.
//
describe("loadSharedHashCache", () => {

    let cacheDir: string;

    beforeEach(() => {
        cacheDir = createTestTempDir("shared-hash-cache-test");
        forgetSharedHashCaches();
    });

    //
    // Writes one entry into the cache on disk, as a separate writer would.
    //
    async function writeAnEntry(key: string, length: number): Promise<void> {
        const writable = new HashCache(cacheDir);
        await writable.load();
        writable.addHash(key, {
            hash: crypto.randomBytes(32),
            length,
            lastModified: new Date(1700000000000),
        });
        await writable.save();
    }

    test("two readers of an unchanged cache get the same one", async () => {
        await writeAnEntry("photo-1.jpg", 100);

        const first = await loadSharedHashCache(cacheDir);
        const second = await loadSharedHashCache(cacheDir);

        expect(second).toBe(first);
    });

    test("a cache that has been written since is read again", async () => {
        await writeAnEntry("photo-1.jpg", 100);
        const first = await loadSharedHashCache(cacheDir);

        await writeAnEntry("photo-2.jpg", 200);
        const second = await loadSharedHashCache(cacheDir);

        expect(second).not.toBe(first);
        expect(second.getHash("photo-2.jpg")).toBeDefined();
    });

    test("a cache that is not there yet is read once it appears", async () => {
        const before = await loadSharedHashCache(cacheDir);
        expect(before.getHash("photo-1.jpg")).toBeUndefined();

        await writeAnEntry("photo-1.jpg", 100);

        const after = await loadSharedHashCache(cacheDir);
        expect(after.getHash("photo-1.jpg")).toBeDefined();
    });

    test("caches in different directories are kept apart", async () => {
        const otherDir = createTestTempDir("shared-hash-cache-other-test");
        await writeAnEntry("photo-1.jpg", 100);

        const here = await loadSharedHashCache(cacheDir);
        const there = await loadSharedHashCache(otherDir);

        expect(there).not.toBe(here);
        expect(there.getHash("photo-1.jpg")).toBeUndefined();
    });
});
