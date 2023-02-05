/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { base64StringToBlob } from 'blob-util';
import { loadFileToDataURL } from '../../lib/file';

describe("file", () => {

    const contentType = "image/png";
    const base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC";
    const testImg = `data:${contentType};base64,${base64Data}`;

    test("can load file to data URL", async () => {

        const blob = base64StringToBlob(base64Data, contentType);
        const dataURL = await loadFileToDataURL(blob);
        expect(dataURL).toEqual(testImg);
    });

});