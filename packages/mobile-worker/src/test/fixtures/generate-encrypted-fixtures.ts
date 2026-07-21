//
// Generates the checked-in encrypted fixtures used by the mobile crypto shim tests.
//
// IMPORTANT: run this ONCE, by hand, on Node (`bun run packages/mobile-worker/src/test/fixtures/
// generate-encrypted-fixtures.ts`). It is NEVER run by the test suite. The fixtures are the ORACLE:
// they are produced here by the real `packages/encryption` code on Node (Node's RSA-OAEP-SHA1 + AES),
// and the mobile shim test decrypts them to prove the mobile implementation matches the desktop format.
// Regenerating them from the mobile implementation would silently turn that test into a tautology, so
// do not wire this into the test run. If a fixture ever legitimately needs regenerating, that is a
// deliberate act (the on-disk encrypted format changed) requiring this Node run and a review of why.
//
// The private key written here (test-only-do-not-use.private.pem) is a real RSA-4096 key generated for
// this purpose only. It guards nothing, is used solely to prove decryption, and must never be reused.
//

import * as fs from "fs";
import * as path from "path";
import { KeyObject } from "crypto";
import { generateKeyPair, exportPublicKeyToPem, encryptBuffer, createEncryptionStream } from "encryption";

//
// The directory the fixtures are written to (this file's own directory + /encrypted).
//
const fixtureDir = path.join(__dirname, "encrypted");

//
// Generates the keypair, the encrypted buffer fixture, and the encrypted stream fixture, plus their
// expected plaintexts, and writes them all under the encrypted/ directory.
//
async function main(): Promise<void> {
    fs.mkdirSync(fixtureDir, { recursive: true });

    const keyPair = generateKeyPair();
    const publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);
    const privateKeyPem = keyPair.privateKey.export({ type: "pkcs8", format: "pem" }) as string;

    fs.writeFileSync(path.join(fixtureDir, "test-only-do-not-use.public.pem"), publicKeyPem);
    fs.writeFileSync(path.join(fixtureDir, "test-only-do-not-use.private.pem"), privateKeyPem);

    // Buffer fixture.
    const bufferPlaintext = Buffer.from("Photosphere mobile crypto fixture: encrypted buffer round-trip.\n", "utf8");
    const encryptedBuffer = encryptBuffer(keyPair.publicKey, bufferPlaintext);
    fs.writeFileSync(path.join(fixtureDir, "buffer.plaintext.txt"), bufferPlaintext);
    fs.writeFileSync(path.join(fixtureDir, "buffer.encrypted.bin"), encryptedBuffer);

    // Stream fixture: push a multi-chunk plaintext through the encryption stream and collect the output.
    const streamPlaintext = Buffer.concat([
        Buffer.from("Photosphere mobile crypto fixture: encrypted stream round-trip.\n", "utf8"),
        Buffer.alloc(5000, 0x41),
    ]);
    const encryptedStream = await runEncryptionStream(keyPair.publicKey, streamPlaintext);
    fs.writeFileSync(path.join(fixtureDir, "stream.plaintext.txt"), streamPlaintext);
    fs.writeFileSync(path.join(fixtureDir, "stream.encrypted.bin"), encryptedStream);

    process.stdout.write(`Wrote encrypted fixtures to ${fixtureDir}\n`);
}

//
// Pushes a plaintext buffer through the encryption stream in two chunks and returns the encrypted bytes.
//
function runEncryptionStream(publicKey: KeyObject, plaintext: Buffer): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const stream = createEncryptionStream(publicKey);
        const chunks: Buffer[] = [];
        stream.on("data", chunk => chunks.push(Buffer.from(chunk)));
        stream.on("end", () => resolve(Buffer.concat(chunks)));
        stream.on("error", reject);
        const half = Math.floor(plaintext.length / 2);
        stream.write(plaintext.subarray(0, half));
        stream.write(plaintext.subarray(half));
        stream.end();
    });
}

void main();
