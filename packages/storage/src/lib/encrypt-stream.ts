import { createCipheriv, createDecipheriv, Decipher, KeyObject, privateDecrypt, publicEncrypt, randomBytes } from "node:crypto";
import { Duplex, Transform } from "node:stream";

//
// Creates a stream to encrypt data using a public key.
//
export function createEncryptionStream(publicKey: KeyObject): Duplex {

    const key = randomBytes(32);
    const iv = randomBytes(16);
    const cipher = createCipheriv('aes-256-cbc', key, iv);

    let headerSent = false;

    return new Transform({
        transform(chunk, encoding, callback) {
            if (!headerSent) {
                const encryptedKey = publicEncrypt(publicKey, key);
                this.push(encryptedKey);
                this.push(iv);
                headerSent = true;
            }

            this.push(cipher.update(chunk));
            callback();
        },

        flush(callback) {
            this.push(cipher.final());
            callback();
        },
    });
}

//
// Creates a stream to decrypt data using a private key.
//
export function createDecryptionStream(privateKey: KeyObject): Duplex {

    let decipher: Decipher | undefined = undefined;
    let header: Buffer | undefined = undefined;

    return new Transform({
        transform(chunk, encoding, callback) {
            if (!decipher) {
                if (!header) {
                    header = chunk;
                }
                else {
                    header = Buffer.concat([header, chunk]);
                }

                if (header!.length >= 512 + 12) {
                    const encryptedKey = header!.slice(0, 512);
                    const iv = header!.slice(512, 512 + 16);
                    const key = privateDecrypt(privateKey, encryptedKey);
                    decipher = createDecipheriv('aes-256-cbc', key, iv);
                    this.push(decipher.update(header!.slice(512 + 16)));
                    header = undefined;
                }
            }
            else {
                this.push(decipher!.update(chunk));
            }

            callback();
        },

        flush(callback) {
            if (decipher) {
                this.push(decipher.final());
            }
            callback();
        },
    });
}

