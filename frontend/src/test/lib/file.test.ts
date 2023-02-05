/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { base64StringToBlob } from 'blob-util';
import { computeHash, loadArrayBuffer, loadDataURL } from '../../lib/file';

describe("file", () => {

    const contentType = "image/png";
    const base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC";
    const testImg = `data:${contentType};base64,${base64Data}`;
    const expectedHash = "7f638ceca5e97ca4995c585fbe4d8e07db40ad3e862550deb9fb93f8340e9f95";

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

    test("can compute hash", async () => {
        const blob = base64StringToBlob(base64Data, contentType);
        const hash = await computeHash(blob);
        expect(hash).toEqual(expectedHash);
    });
});