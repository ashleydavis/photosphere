import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree, getItemInfo, loadTree } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { Readable } from "stream";
import { pushFiles } from "../../lib/sync";

//
// What a push tells the target about the length of each file it sends.
//
// A database that is encrypted at rest holds ciphertext, and the store underneath it reports the size
// of that ciphertext while the stream it hands out is the plaintext, 576 bytes shorter. Taking the
// length from the store and handing it over as the length of the stream made the target declare a
// Content-Length it then fell 576 bytes short of. Measured on a Pixel 6 pushing to MinIO on the same
// LAN, S3 waited thirty seconds for a remainder that was never coming and refused every file with "A
// timeout occurred while trying to lock a resource, please reduce your request rate", three attempts
// each, and the sync copied nothing at all for as long as it was left running.
//
// The second half of the same fault is quieter and would have outlived the first: the target's tree
// was written under the ciphertext length too, so it never matched the source's, and every file
// copied stayed in the difference and was copied again on the next pass, for ever.
//

const dbId = "7c3d4e5f-8a9b-4c0d-9e1f-2a3b4c5d6e7f";

//
// How much longer the stored file is than what the database holds, as the encrypted format makes it.
//
const ENCRYPTION_OVERHEAD = 576;

//
// The database's own hash of a file's contents.
//
function hashOf(contents: string): Buffer {
    return createHash("sha256").update(Buffer.from(contents, "utf-8")).digest();
}

//
// A storage that reads and writes what the database holds while the file underneath it is longer,
// which is what encrypted storage is: `info` describes the stored bytes and `readStream` hands back
// the shorter plaintext.
//
class StoredLongerThanItReadsStorage extends MockStorage {

    //
    // The size of the stored file, which is what any store reports about the file on its disk.
    //
    async info(filePath: string): Promise<any> {
        const info = await super.info(filePath);
        if (!info) {
            return undefined;
        }
        return {
            contentType: info.contentType,
            length: info.length + ENCRYPTION_OVERHEAD,
            lastModified: info.lastModified,
        };
    }
}

//
// A storage that records the length each write was told to expect, which is what becomes the
// Content-Length of the request that carries it.
//
class LengthRecordingStorage extends MockStorage {

    // The length declared for each file written, by file name.
    readonly declaredLengths: Map<string, number> = new Map();

    async writeStreamHashed(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength: number, sha256: Buffer): Promise<boolean> {
        this.declaredLengths.set(filePath, contentLength);
        return super.writeStreamHashed(filePath, contentType, inputStream, contentLength, sha256);
    }
}

//
// Fills a storage with the given files and a merkle tree describing exactly them, under the lengths
// the database holds rather than the lengths of whatever the store keeps underneath.
//
async function fillDatabase(storage: MockStorage, fileNames: string[]): Promise<void> {
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const fileName of fileNames) {
        const contents = Buffer.from(fileName, "utf-8");
        await storage.write(fileName, "image/jpeg", contents);
        tree = addItem(tree, {
            name: fileName,
            hash: hashOf(fileName),
            length: contents.length,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    tree.databaseMetadata = { filesImported: fileNames.length };
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(".db/files.dat", tree, storage);
}

//
// A bson database that a push only flushes and commits.
//
function makeBsonDatabase(): any {
    return {
        flush: async () => {},
        commit: async () => {},
    };
}

describe("the lengths a push hands over", () => {

    const fileName = "asset/one.jpg";

    test("the length declared for a copy is the length of what the database holds, not of the file under it", async () => {
        const source = new StoredLongerThanItReadsStorage();
        await fillDatabase(source, [ fileName ]);

        const target = new LengthRecordingStorage();
        await fillDatabase(target, []);

        await pushFiles(source, target, makeBsonDatabase());

        expect(target.declaredLengths.get(fileName)).toBe(fileName.length);
    });

    test("the target's tree records the same length as the source's, so the file is not copied again", async () => {
        const source = new StoredLongerThanItReadsStorage();
        await fillDatabase(source, [ fileName ]);

        const target = new MockStorage();
        await fillDatabase(target, []);

        await pushFiles(source, target, makeBsonDatabase());

        const sourceTree = await loadTree<IDatabaseMetadata>(".db/files.dat", source);
        const targetTree = await loadTree<IDatabaseMetadata>(".db/files.dat", target);
        expect(getItemInfo(targetTree!, fileName)!.length).toBe(getItemInfo(sourceTree!, fileName)!.length);
    });
});
