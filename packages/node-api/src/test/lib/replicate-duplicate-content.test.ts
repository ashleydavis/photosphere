import { MockStorage } from "storage";
import { createTree, addItem, buildMerkleTree, saveTree, loadTree, getItemInfo } from "merkle-tree";
import { BsonDatabase } from "bdb";
import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import { createHash } from "crypto";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { replicate } from "../../lib/replicate";

//
// A replication decides what to copy and what to prune by name, not by content.
//
// It used to decide with the merkle diff, and the merkle diff matches leaves by hash: of two files
// with the same content under different names it copied or pruned whichever it visited second, so
// the destination could be left without a file the source has, or with its tree missing a name the
// source's tree has, and a later replication saw nothing to do because the hashes matched. A library
// holds such files whenever a photo has been imported twice. The sync's push had the same fault,
// measured on a Pixel 6 at 243 files never reaching the origin.
//

//
// A file to put in a database: its name and its contents.
//
interface IFileToStore {
    // Where the file lives.
    name: string;

    // What it holds.
    contents: string;
}

const uuidGenerator = new TestUuidGenerator();
const timestampProvider = new MockTimestampProvider();
const dbId = uuidGenerator.generate();

//
// Builds a storage holding the given files and a merkle tree describing exactly them.
//
async function makeDatabase(files: IFileToStore[]): Promise<MockStorage> {
    const storage = new MockStorage();
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const file of files) {
        const contents = Buffer.from(file.contents, "utf-8");
        await storage.write(file.name, "image/jpeg", contents);
        tree = addItem(tree, {
            name: file.name,
            hash: createHash("sha256").update(contents).digest(),
            length: contents.length,
            lastModified: new Date("2026-01-01T00:00:00.000Z"),
        });
    }
    tree.databaseMetadata = { filesImported: files.length };
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    await saveTree(".db/files.dat", tree, storage);
    return storage;
}

//
// Replicates the source into the destination.
//
async function replicateInto(source: MockStorage, destination: MockStorage): Promise<string[]> {
    const sourceBsonDatabase = new BsonDatabase(new MockStorage(), "", uuidGenerator, timestampProvider);
    const result = await replicate(
        "mock://source",
        source,
        sourceBsonDatabase,
        uuidGenerator,
        timestampProvider,
        destination,
        destination,
        undefined,
        undefined
    );
    return result.prunedFiles;
}

describe("replicating files whose content the other side already holds under another name", () => {

    const photo = "the same photo imported twice";

    test("a file the destination lacks arrives under its own name", async () => {
        const source = await makeDatabase([
            {
                name: "asset/first-import",
                contents: photo,
            },
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);
        const destination = await makeDatabase([
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);

        await replicateInto(source, destination);

        expect(await destination.fileExists("asset/first-import")).toBe(true);
        const destinationTree = await loadTree<IDatabaseMetadata>(".db/files.dat", destination);
        expect(getItemInfo(destinationTree!, "asset/first-import")).toBeDefined();
    });

    test("a name only the destination has is the one pruned from its tree", async () => {
        const source = await makeDatabase([
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);
        const destination = await makeDatabase([
            {
                name: "asset/first-import",
                contents: photo,
            },
            {
                name: "asset/second-import",
                contents: photo,
            },
        ]);

        const prunedFiles = await replicateInto(source, destination);

        expect(prunedFiles).toEqual([ "asset/first-import" ]);
        const destinationTree = await loadTree<IDatabaseMetadata>(".db/files.dat", destination);
        expect(getItemInfo(destinationTree!, "asset/first-import")).toBeUndefined();
        expect(getItemInfo(destinationTree!, "asset/second-import")).toBeDefined();
    });
});
