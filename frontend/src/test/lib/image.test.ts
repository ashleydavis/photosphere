/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { getImageResolution, loadFile, loadImage } from "../../lib/image";
import { base64StringToBlob } from 'blob-util';

describe("image", () => {

    const contentType = "image/png";
    const base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC";
    const testImg = `data:${contentType};base64,${base64Data}`;

    test("can load image", async () => {

        const image = await loadImage(testImg);
        expect(image.src).toBe(testImg);
    });

    test("can get image resolution", async () => {

        const resolution = await getImageResolution(testImg);
        expect(resolution).toEqual({
            width: 10,
            height: 10,
        });
    });

    test("can load file", async () => {

        const blob = base64StringToBlob(base64Data, contentType);
        const loadedFile = await loadFile(blob);
        expect(loadedFile).toEqual(testImg);
    });

});