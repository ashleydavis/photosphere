import { createCipheriv, createDecipheriv, KeyObject, privateDecrypt, publicEncrypt, randomBytes } from "node:crypto";

//
// Encrypts a buffer using a public key.
//
export async function encryptBuffer(publicKey: KeyObject, data: Buffer): Promise<Buffer> {
    const key = await randomBytes(32);
    const iv = await randomBytes(16);
    const cipher = createCipheriv('aes-256-cbc', key, iv);
    const encrypted = Buffer.concat([cipher.update(data), cipher.final()]);
    const encryptedKey = publicEncrypt(publicKey, key);
    return Buffer.concat([encryptedKey, iv, encrypted]);
}

//
// Decrypts a buffer using a private key.
//
export async function decryptBuffer(privateKey: KeyObject, data: Buffer): Promise<Buffer> {
    const encryptedKey = data.slice(0, 512);
    const iv = data.slice(512, 512 + 16);
    const encrypted = data.slice(512 + 16);
    const key = privateDecrypt(privateKey, encryptedKey);
    const decipher = createDecipheriv('aes-256-cbc', key, iv);
    const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    return decrypted;
}

