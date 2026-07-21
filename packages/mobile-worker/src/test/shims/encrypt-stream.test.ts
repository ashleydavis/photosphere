import { Buffer } from "buffer";
import * as fs from "fs";
import * as path from "path";

//
// Route the encryption package's `node:crypto` imports to the mobile crypto shim, so
// createEncryptionStream / createDecryptionStream run against the shim exactly as they do in the
// bundle. encrypt-stream.ts imports the same crypto set as encrypt-buffer.ts (createCipheriv,
// createDecipheriv, Decipher, KeyObject, privateDecrypt, publicEncrypt, randomBytes); without the shim
// implementing them this consumer would be left throwing.
//
// Only the `node:` specifier is mocked: the encryption package imports `node:crypto`, while the shim's
// own pure-JS deps (browserify-aes/create-hmac/create-hash) require the bare `crypto`, which must stay
// the real Node crypto (mocking it too would make the shim's createCipheriv recurse into itself).
jest.mock("node:crypto", () => require("../../shims/node-crypto"));

import { createEncryptionStream, createDecryptionStream, hashPublicKey, type IPrivateKeyMap } from "encryption";
import { createPublicKey, createPrivateKey, type KeyObject } from "../../shims/node-crypto";

//
// Real Node crypto (bypassing the mock above), used to back the native RSA host functions the shim
// calls, with Node's default OAEP-SHA1 padding — what the native Java/Swift implementations must match.
//
const nodeCrypto = jest.requireActual("crypto") as typeof import("crypto");

//
// The directory holding the checked-in desktop-produced encrypted fixtures.
//
const FIXTURE_DIR = path.join(__dirname, "..", "fixtures", "encrypted");

//
// Installs the mock native crypto host backed by real Node crypto.
//
function installMockCryptoHost(): void {
    (globalThis as any).host = {
        platform: "android",
        cryptoPublicEncryptOaepSha1: (publicKeyPem: string, dataBase64: string): string =>
            nodeCrypto.publicEncrypt(publicKeyPem, Buffer.from(dataBase64, "base64")).toString("base64"),
        cryptoPrivateDecryptOaepSha1: (privateKeyPem: string, dataBase64: string): string =>
            nodeCrypto.privateDecrypt(privateKeyPem, Buffer.from(dataBase64, "base64")).toString("base64"),
    };
}

//
// Runs a Transform stream: writes the given chunks, ends, and resolves with the concatenated output.
//
function runStream(stream: NodeJS.ReadWriteStream, chunks: Buffer[]): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const output: Buffer[] = [];
        stream.on("data", chunk => output.push(Buffer.from(chunk)));
        stream.on("end", () => resolve(Buffer.concat(output)));
        stream.on("error", reject);
        for (const chunk of chunks) {
            stream.write(chunk);
        }
        stream.end();
    });
}

//
// Loads the fixture keypair as shim KeyObjects and builds the decryption key map keyed by public-key hash.
//
function loadFixtureKeys(): { publicKey: KeyObject; privateKeyMap: IPrivateKeyMap } {
    const publicKeyPem = fs.readFileSync(path.join(FIXTURE_DIR, "test-only-do-not-use.public.pem"), "utf8");
    const privateKeyPem = fs.readFileSync(path.join(FIXTURE_DIR, "test-only-do-not-use.private.pem"), "utf8");
    const publicKey = createPublicKey(publicKeyPem);
    const privateKey = createPrivateKey(privateKeyPem);
    const keyHashHex = hashPublicKey(publicKey as never).toString("hex");
    const privateKeyMap: IPrivateKeyMap = { default: privateKey as never, [keyHashHex]: privateKey as never };
    return { publicKey, privateKeyMap };
}

describe("encrypt-stream against the mobile crypto shim", () => {

    beforeEach(() => {
        installMockCryptoHost();
    });

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("createEncryptionStream/createDecryptionStream round-trip a multi-chunk payload", async () => {
        const { publicKey, privateKeyMap } = loadFixtureKeys();
        const plaintext = Buffer.concat([
            Buffer.from("mobile encryption stream round-trip ", "utf8"),
            Buffer.alloc(3000, 0x42),
        ]);

        const encrypted = await runStream(createEncryptionStream(publicKey as never) as NodeJS.ReadWriteStream, [
            plaintext.subarray(0, 1000),
            plaintext.subarray(1000),
        ]);
        const decrypted = await runStream(createDecryptionStream(privateKeyMap) as NodeJS.ReadWriteStream, [encrypted]);
        expect(decrypted.equals(plaintext)).toBe(true);
    });

    test("decrypts the checked-in desktop stream fixture to its expected plaintext", async () => {
        const { privateKeyMap } = loadFixtureKeys();
        const encrypted = fs.readFileSync(path.join(FIXTURE_DIR, "stream.encrypted.bin"));
        const expected = fs.readFileSync(path.join(FIXTURE_DIR, "stream.plaintext.txt"));
        const decrypted = await runStream(createDecryptionStream(privateKeyMap) as NodeJS.ReadWriteStream, [encrypted]);
        expect(decrypted.equals(expected)).toBe(true);
    });
});
