import { Readable } from "stream";
import { generateKeyPairSync } from "node:crypto";
import { computeEncryptedLength, hashPublicKey, type IPrivateKeyMap } from "encryption";
import { EncryptedStorage } from "../lib/encrypted-storage";
import { MockStorage } from "./mock-storage";
import type { IFileInfo } from "../lib/storage";

//
// What encrypted storage says about how long a file is.
//
// Everything else it exposes is the file the database holds: `read` and `readStream` decrypt on the
// way out, `write` and `writeStream` encrypt on the way in. `info` is the exception and describes the
// stored file, which is the ciphertext, and no arithmetic turns that back into the length of the
// plaintext: the format pads the last block out to sixteen bytes and how much of it is padding is
// only known once it has been decrypted.
//
// A copy has to say how long it is before it sends a byte, so a caller that took the stored size and
// declared it made every upload promise more than it sent. Measured on a Pixel 6 pushing to MinIO on
// the same LAN, S3 waited thirty seconds for a remainder that was never coming and refused every
// file with "A timeout occurred while trying to lock a resource, please reduce your request rate",
// three attempts each, and the sync copied nothing at all for as long as it was left running.
//

//
// A storage that records the length each stream write was told to expect, which is what becomes the
// Content-Length of the request that carries it.
//
class LengthRecordingStorage extends MockStorage {

    // The length declared for each file written, by file name. Undefined for a write that declared
    // none.
    readonly declaredLengths: Map<string, number | undefined> = new Map();

    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        this.declaredLengths.set(filePath, contentLength);
        return super.writeStream(filePath, contentType, inputStream, contentLength);
    }
}

//
// An encrypted storage over the given store, with a key pair made for the test.
//
function makeEncryptedStorage(underlying: MockStorage): EncryptedStorage {
    const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 4096 });
    const keyHashHex = hashPublicKey(publicKey).toString("hex");
    const decryptionKeyMap: IPrivateKeyMap = {
        default: privateKey,
        [keyHashHex]: privateKey,
    };
    return new EncryptedStorage("encrypted", underlying, decryptionKeyMap, publicKey);
}

describe("the lengths encrypted storage reports", () => {

    //
    // Fifteen bytes of padding and one, and every count between, all land on the same stored length,
    // which is exactly why the stored length cannot be turned back into the plaintext's.
    //
    test("it will not say how long a read is, because the stored length cannot say", () => {
        const storage = makeEncryptedStorage(new MockStorage());

        for (let plainLength = 1; plainLength <= 64; plainLength++) {
            const fileInfo: IFileInfo = {
                contentType: "image/jpeg",
                length: computeEncryptedLength(plainLength),
                lastModified: new Date("2026-01-01T00:00:00.000Z"),
            };
            expect(storage.readableLength(fileInfo)).toBeUndefined();
        }
    });

    test("a write given no length declares none to the store underneath", async () => {
        const underlying = new LengthRecordingStorage();
        const storage = makeEncryptedStorage(underlying);

        const contents = Buffer.from("a thumbnail's worth of bytes", "utf-8");
        await storage.writeStreamHashed("thumb/one.jpg", "image/jpeg", Readable.from([ contents ]), undefined, Buffer.alloc(32, 7));

        expect(underlying.declaredLengths.get("thumb/one.jpg")).toBeUndefined();

        // The bytes still made the trip, and come back out as what went in.
        expect(await storage.read("thumb/one.jpg")).toEqual(contents);
    });

    //
    // A caller that does know the plaintext's length, an import writing bytes it is holding, still
    // gets an exact one declared, which is what lets a write stream instead of being counted first.
    //
    test("a write given a length declares what the ciphertext will come to", async () => {
        const underlying = new LengthRecordingStorage();
        const storage = makeEncryptedStorage(underlying);

        const contents = Buffer.from("a thumbnail's worth of bytes", "utf-8");
        await storage.writeStream("thumb/two.jpg", "image/jpeg", Readable.from([ contents ]), contents.length);

        expect(underlying.declaredLengths.get("thumb/two.jpg")).toBe(computeEncryptedLength(contents.length));

        const stored = await underlying.read("thumb/two.jpg");
        expect(stored!.length).toBe(computeEncryptedLength(contents.length));
    });
});
