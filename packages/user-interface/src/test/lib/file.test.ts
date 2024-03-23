/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { base64StringToBlob } from 'blob-util';
import { computeHash, loadArrayBuffer, loadDataURL } from '../../lib/file';

describe("file", () => {

    const contentType = "image/png";
    const base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC";
    const testImg = `data:${contentType};base64,${base64Data}`;

    test("can load file to data URL", async () => {
        const blob = base64StringToBlob(base64Data, contentType);
        const dataURL = await loadDataURL(blob);
        expect(dataURL).toEqual(testImg);
    });

    test("can load file to array buffer", async () => {
        const blob = base64StringToBlob(base64Data, contentType);
        const arrayBuffer = await loadArrayBuffer(blob);
        const base64 = await loadDataURL(new Blob([arrayBuffer], { type: contentType }));
        expect(base64).toEqual(testImg);
    });

    //
    // Loads a hex string to an ArrayBuffer.
    //
    function hexToUint8Array(hexString: string): ArrayBuffer {
        if (hexString.length % 2 !== 0) {
            throw new Error('Invalid hexString length. Hex string must have an even number of characters.');
        }
        
        const byteArray = new Uint8Array(hexString.length / 2);
        
        for (let i = 0; i < byteArray.length; i++) {
            const byteValue = parseInt(hexString.substring(i * 2, i * 2 + 2), 16);
            byteArray[i] = byteValue;
        }
        
        return byteArray.buffer;
    }

    test("can compute hash", async () => {
        //
        // Mock the hash function because it's not implemented under Node.js
        //
        const expectedHash = "12347f638ceca5e97ca4995c585fbe4d8e07db40ad3e862550deb9fb93f8340e9f95";
        const crypto: any = {};

        Object.defineProperty(globalThis, 'crypto', {
            value: crypto,
        });

        crypto.subtle = {
                digest: async () => hexToUint8Array(expectedHash),
        };

        const blob = base64StringToBlob(base64Data, contentType);
        const hash = await computeHash(blob);
        expect(hash).toEqual(expectedHash);
    });
});