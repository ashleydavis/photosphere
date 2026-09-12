import { MockStorage } from "storage";
import type { IFileInfo } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree, getItemInfo, loadTree } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { createHash } from "crypto";
import { Readable } from "stream";
import { pushFiles } from "../../lib/sync";

//
// What a push tells the target about the length of each file it sends.
//
// A database that is encrypted at rest holds ciphertext and reads out plaintext, and the plaintext's
// length cannot be worked back out of the ciphertext's, so the store says it cannot say. Taking the
// stored size instead and handing it over as the length of the stream made the target declare a
// Content-Length it then fell short of by the encryption's overhead. Measured on a Pixel 6 pushing to
// MinIO on the same LAN, S3 waited thirty seconds for a remainder that was never coming and refused
// every file with "A timeout occurred while trying to lock a resource, please reduce your request
// rate", three attempts each, and the sync copied nothing at all for as long as it was left running.
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
// A storage that reads out something shorter than the file it holds and cannot say how much shorter,
// which is what encrypted storage is.
//
class CannotSayHowLongItReadsStorage extends MockStorage {

    //
    // The size of the stored file, which is what any store reports about the file on its disk.
    //
    async info(filePath: string): Promise<IFileInfo | undefined> {
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

    //
    // Unknowable, because what is read out is not what is stored.
    //
    readableLength(fileInfo: IFileInfo): number | undefined {
        return undefined;
    }
}

//
// A storage that records the length each write was told to expect, which is what becomes the
// Content-Length of the request that carries it.
//
class LengthRecordingStorage extends MockStorage {

    // The length declared for each file written, by file name. Undefined for a write that declared
    // none.
    readonly declaredLengths: Map<string, number | undefined> = new Map();

    async writeStreamHashed(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength: number | undefined, sha256: Buffer): Promise<boolean> {
        this.declaredLengths.set(filePath, contentLength);
        return super.writeStreamHashed(filePath, contentType, inputStream, contentLength, sha256);
    }
}

//
// Fills a storage with the given files and a merkle tree describing exactly them, under the lengths
// the store reports, which is what every import records.
//
async function fillDatabase(storage: MockStorage, fileNames: string[]): Promise<void> {
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const fileName of fileNames) {
        const contents = Buffer.from(fileName, "utf-8");
        await storage.write(fileName, "image/jpeg", contents);
        const info = await storage.info(fileName);
        tree = addItem(tree, {
            name: fileName,
            hash: hashOf(fileName),
            length: info!.length,
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

    test("a source that cannot say how long it reads has no length declared for it", async () => {
        const source = new CannotSayHowLongItReadsStorage();
        await fillDatabase(source, [ fileName ]);

        const target = new LengthRecordingStorage();
        await fillDatabase(target, []);

        await pushFiles(source, target, makeBsonDatabase());

        expect(target.declaredLengths.has(fileName)).toBe(true);
        expect(target.declaredLengths.get(fileName)).toBeUndefined();
    });

    test("a source that reads out what it stores has its own length declared for it", async () => {
        const source = new MockStorage();
        await fillDatabase(source, [ fileName ]);

        const target = new LengthRecordingStorage();
        await fillDatabase(target, []);

        await pushFiles(source, target, makeBsonDatabase());

        expect(target.declaredLengths.get(fileName)).toBe(fileName.length);
    });

    test("the target's tree records the same length as the source's, so the file is not copied again", async () => {
        const source = new CannotSayHowLongItReadsStorage();
        await fillDatabase(source, [ fileName ]);

        const target = new MockStorage();
        await fillDatabase(target, []);

        await pushFiles(source, target, makeBsonDatabase());

        const sourceTree = await loadTree<IDatabaseMetadata>(".db/files.dat", source);
        const targetTree = await loadTree<IDatabaseMetadata>(".db/files.dat", target);
        expect(getItemInfo(targetTree!, fileName)!.length).toBe(getItemInfo(sourceTree!, fileName)!.length);
    });
});
