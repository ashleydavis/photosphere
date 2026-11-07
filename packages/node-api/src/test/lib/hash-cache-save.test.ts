//
// Tests for how HashCache.save() tells lock contention apart from a real fault.
//
// Contention is not an error worth reporting: the cache is an optimization, the changeset stays
// pending, and the next save carries it. A real fault is the opposite, and this suite exists
// because one was silently swallowed for the whole life of the mobile app: the embedded engine's
// fs shim had no `open`, so the lock call threw a TypeError, save()'s bare catch ate it, and the
// mobile hash cache never persisted a single entry.
//
// The rethrow case is driven by removing `open` from `fs/promises`, which is exactly the hole the
// mobile shim had, rather than by asserting against a message this suite made up.
//

import * as path from "path";
import * as realFs from "fs/promises";
import { HashCache } from "../../lib/hash-cache";
import { createTestTempDir } from "node-utils";

//
// When true the mocked `fs/promises` reports no `open` at all, reproducing the mobile shim's hole.
// Named with the `mock` prefix because jest only allows out-of-scope variables into a mock factory
// under that name.
//
let mockHideFsOpen = false;

jest.mock("fs/promises", () => {
    const actualFsPromises = jest.requireActual("fs/promises");
    return {
        ...actualFsPromises,

        //
        // A getter rather than a function, so that with the hole open the property really is
        // `undefined` and the caller gets the genuine "fs.open is not a function" TypeError instead
        // of one this test threw on its behalf.
        //
        get open() {
            return mockHideFsOpen ? undefined : actualFsPromises.open;
        },
    };
});

//
// Builds a loaded, dirty cache in its own directory and returns both.
//
async function makeDirtyCache(): Promise<{ cache: HashCache; cacheDir: string }> {
    const cacheDir = createTestTempDir("hash-cache-save-test");
    const cache = new HashCache(cacheDir);
    await cache.load();
    cache.addHash("a/one.txt", {
        hash: Buffer.alloc(32, 7),
        length: 11,
        lastModified: new Date(2024, 0, 1),
    });
    return {
        cache,
        cacheDir,
    };
}

describe("HashCache.save error handling", () => {

    afterEach(() => {
        mockHideFsOpen = false;
    });

    test("returns quietly when the update lock is held by somebody else", async () => {
        const { cache, cacheDir } = await makeDirtyCache();

        // Hold the lock the way another writer would, and leave it held. It stays well inside the
        // staleness threshold for the duration of this test, so it is never broken.
        const cachePath = path.join(cacheDir, "hash-cache-x.dat");
        await realFs.mkdir(cacheDir, { recursive: true });
        await realFs.writeFile(`${cachePath}.lock`, "");

        await expect(cache.save()).resolves.toBeUndefined();

        // Nothing was published, because the save never got in.
        await expect(realFs.access(cachePath)).rejects.toMatchObject({ code: "ENOENT" });

        // The changeset was kept, so the entry lands as soon as the lock is free.
        await realFs.rm(`${cachePath}.lock`);
        await cache.save();
        await expect(realFs.access(cachePath)).resolves.toBeUndefined();
    });

    test("rethrows when the update fails for a reason that is not contention", async () => {
        const { cache } = await makeDirtyCache();

        // This is the mobile bug exactly: `fs/promises` has no `open`, so taking the lock throws a
        // TypeError. Before the catch was narrowed this was swallowed and save() resolved.
        mockHideFsOpen = true;

        await expect(cache.save()).rejects.toThrow(TypeError);
    });
});
