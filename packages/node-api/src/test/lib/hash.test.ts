import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { computeFileHash, getNativeFileHasher } from "../../lib/hash";

//
// A directory that lives for the length of the test file, holding the files that get hashed.
//
const workingDir = mkdtempSync(join(tmpdir(), "photosphere-hash-test-"));

//
// Writes a file with the given contents and returns its path.
//
function writeTestFile(name: string, contents: Buffer): string {
    const filePath = join(workingDir, name);
    writeFileSync(filePath, contents);
    return filePath;
}

describe("computeFileHash", () => {

    test("there is no native file hasher when crypto is Node's own", () => {
        // Which is every platform except the mobile worker. There the bundler resolves `crypto` to
        // the mobile shim, which does export one; nothing else does, so the import path is what
        // answers the question and no platform check is written anywhere.
        expect(getNativeFileHasher()).toBeUndefined();
    });

    test("streams the file through a JS hash when no native hasher is handed in", async () => {
        const contents = Buffer.from("the quick brown fox", "utf8");
        const filePath = writeTestFile("streamed.bin", contents);

        const expected = createHash("sha256").update(contents).digest();
        expect(await computeFileHash(filePath, undefined)).toEqual(expected);
    });

    test("uses the native hasher when one is handed in, and hands it the file's path", async () => {
        const filePath = writeTestFile("native.bin", Buffer.from("the quick brown fox", "utf8"));

        // Deliberately answers something the streaming path could never produce, so the test can
        // tell which path ran rather than assuming it from the digest coming out right.
        const sentinel = Buffer.alloc(32, 0xab);
        let askedFor: string | undefined = undefined;

        const digest = await computeFileHash(filePath, (askedPath: string) => {
            askedFor = askedPath;
            return sentinel;
        });

        expect(digest).toEqual(sentinel);
        expect(askedFor).toBe(filePath);
    });

    test("the native path and the streaming path agree on the same bytes", async () => {
        // The one property that is not negotiable. These digests are the identity of every asset and
        // the key of the hash cache, so a native hash differing from the streamed one by a byte
        // would make every database already written look wrong, and silently: photos would
        // re-import and the cache would never hit. The native implementations are pinned to the
        // same published vectors on both devices (HostFunctionsTest, HostBridgeTests).
        const contents = Buffer.alloc(3 * 1024 * 1024);
        for (let index = 0; index < contents.length; index++) {
            contents[index] = index % 251;
        }
        const filePath = writeTestFile("agreement.bin", contents);

        const streamed = await computeFileHash(filePath, undefined);

        // Stands in for the platform hash: the same algorithm over the same bytes, which is exactly
        // what CommonCrypto and java.security.MessageDigest compute on the two devices.
        const nativelyHashed = await computeFileHash(filePath, () => createHash("sha256").update(contents).digest());

        expect(nativelyHashed).toEqual(streamed);
    });

    test("hashes an empty file the same way down both paths", async () => {
        const filePath = writeTestFile("empty.bin", Buffer.alloc(0));

        const streamed = await computeFileHash(filePath, undefined);
        expect(streamed).toEqual(createHash("sha256").digest());

        const nativelyHashed = await computeFileHash(filePath, () => createHash("sha256").digest());
        expect(nativelyHashed).toEqual(streamed);
    });
});
