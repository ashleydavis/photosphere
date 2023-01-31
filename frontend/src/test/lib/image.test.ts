/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { getImageResolution, loadImage } from "../../lib/image";

describe("image", () => {

    // const src = "https://codecapers.com.au/assets/img/profile.jpg";
    const testImg = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC";

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

});