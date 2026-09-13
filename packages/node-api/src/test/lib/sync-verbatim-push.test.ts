import { MockStorage, EncryptedStorage } from "storage";
import type { IStorage } from "storage";
import { generateKeyPairSync, createHash, type KeyObject } from "node:crypto";
import { hashPublicKey, type IPrivateKeyMap } from "encryption";
import { createTree, addItem, buildMerkleTree, saveTree, getItemInfo, loadTree } from "merkle-tree";
import type { IDatabaseMetadata } from "../../lib/media-file-database";
import { pushFiles, chooseHowToPushBytes } from "../../lib/sync";

//
// How a push moves a file between two databases encrypted under the same key.
//
// The stored bytes go across as they are. The ciphertext one database holds is exactly the
// ciphertext the other would write, so decrypting it on the way out and encrypting it again on the
// way in changes nothing but the time it takes, and on a phone that time is the whole cost of
// pushing an original: AES-256-CBC there runs in the engine's own JavaScript at about a fifth of a
// megabyte a second in each direction. Measured on a Pixel 6, a three megabyte photo took thirty
// seconds to push and a ninety megabyte video a quarter of an hour, for bytes the network carries
// in a few seconds.
//

const dbId = "8d4e5f6a-9b0c-4d1e-af2b-3c4d5e6f7a8b";

//
// A key pair and the key map that reads what it wrote, as one database's keys.
//
interface IDatabaseKeys {
    // The public key files are encrypted with.
    publicKey: KeyObject;

    // The private keys files are decrypted with, by public key hash.
    decryptionKeyMap: IPrivateKeyMap;

    // The public key as it is written to `.db/encryption.pub`.
    publicKeyPem: string;
}

//
// Makes a fresh key pair.
//
function makeKeys(): IDatabaseKeys {
    const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 4096 });
    return {
        publicKey,
        decryptionKeyMap: {
            default: privateKey,
            [hashPublicKey(publicKey).toString("hex")]: privateKey,
        },
        publicKeyPem: publicKey.export({ type: "spki", format: "pem" }) as string,
    };
}

//
// An encrypted database over an in-memory store: the raw store, the storage that reads and writes
// through the encryption, and the key file that names its key.
//
interface IEncryptedDatabase {
    // What is stored: ciphertext.
    raw: MockStorage;

    // What the database holds: plaintext, through the encryption.
    storage: EncryptedStorage;
}

//
// Makes an encrypted database under the given keys, holding the given files.
//
async function makeEncryptedDatabase(keys: IDatabaseKeys, fileNames: string[]): Promise<IEncryptedDatabase> {
    const raw = new MockStorage();
    const storage = new EncryptedStorage("encrypted", raw, keys.decryptionKeyMap, keys.publicKey);
    await raw.write(".db/encryption.pub", undefined, Buffer.from(keys.publicKeyPem, "utf-8"));
    await fillDatabase(storage, fileNames);
    return {
        raw,
        storage,
    };
}

//
// Fills a storage with the given files and a merkle tree describing exactly them.
//
async function fillDatabase(storage: IStorage, fileNames: string[]): Promise<void> {
    let tree = createTree<IDatabaseMetadata>(dbId);
    for (const fileName of fileNames) {
        const contents = Buffer.from(`the contents of ${fileName}`, "utf-8");
        await storage.write(fileName, "image/jpeg", contents);
        tree = addItem(tree, {
            name: fileName,
            hash: createHash("sha256").update(contents).digest(),
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

describe("a push between databases encrypted under the same key", () => {

    const fileName = "asset/one.jpg";

    test("moves the stored bytes as they are", async () => {
        const keys = makeKeys();
        const source = await makeEncryptedDatabase(keys, [ fileName ]);
        const target = await makeEncryptedDatabase(keys, []);

        const bytes = await chooseHowToPushBytes(source.storage, source.raw, target.storage, target.raw);
        expect(bytes.verbatim).toBe(true);

        await pushFiles(source.storage, target.storage, makeBsonDatabase(), bytes);

        // Byte for byte the source's ciphertext, which it could only be if nothing was decrypted
        // and encrypted again on the way: a fresh encryption draws a fresh key and a fresh IV.
        expect(await target.raw.read(fileName)).toEqual(await source.raw.read(fileName));

        // And the target reads it back as what the database holds.
        expect(await target.storage.read(fileName)).toEqual(Buffer.from(`the contents of ${fileName}`, "utf-8"));
    });

    test("hands the store the hash of the stored bytes, so the store can check them", async () => {
        const keys = makeKeys();
        const source = await makeEncryptedDatabase(keys, [ fileName ]);
        const target = await makeEncryptedDatabase(keys, []);

        await pushFiles(source.storage, target.storage, makeBsonDatabase(), await chooseHowToPushBytes(source.storage, source.raw, target.storage, target.raw));

        const storedBytes = await source.raw.read(fileName);
        expect(await target.raw.storedHash(fileName)).toEqual(createHash("sha256").update(storedBytes!).digest());
    });

    test("records the file in the target's tree as the source's tree has it", async () => {
        const keys = makeKeys();
        const source = await makeEncryptedDatabase(keys, [ fileName ]);
        const target = await makeEncryptedDatabase(keys, []);

        await pushFiles(source.storage, target.storage, makeBsonDatabase(), await chooseHowToPushBytes(source.storage, source.raw, target.storage, target.raw));

        const sourceTree = await loadTree<IDatabaseMetadata>(".db/files.dat", source.storage);
        const targetTree = await loadTree<IDatabaseMetadata>(".db/files.dat", target.storage);
        expect(getItemInfo(targetTree!, fileName)).toEqual(getItemInfo(sourceTree!, fileName));
    });
});

describe("a push between databases that do not share a key", () => {

    const fileName = "asset/one.jpg";

    test("goes through the databases, decrypting and encrypting on the way", async () => {
        const source = await makeEncryptedDatabase(makeKeys(), [ fileName ]);
        const target = await makeEncryptedDatabase(makeKeys(), []);

        const bytes = await chooseHowToPushBytes(source.storage, source.raw, target.storage, target.raw);
        expect(bytes.verbatim).toBe(false);

        await pushFiles(source.storage, target.storage, makeBsonDatabase(), bytes);

        expect(await target.raw.read(fileName)).not.toEqual(await source.raw.read(fileName));
        expect(await target.storage.read(fileName)).toEqual(Buffer.from(`the contents of ${fileName}`, "utf-8"));
    });

    test("is never verbatim when either side is not encrypted", async () => {
        const encrypted = await makeEncryptedDatabase(makeKeys(), [ fileName ]);
        const plain = new MockStorage();
        await fillDatabase(plain, []);

        expect((await chooseHowToPushBytes(encrypted.storage, encrypted.raw, plain, plain)).verbatim).toBe(false);
        expect((await chooseHowToPushBytes(plain, plain, encrypted.storage, encrypted.raw)).verbatim).toBe(false);
    });
});
