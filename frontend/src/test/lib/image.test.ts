/** 
 * @jest-environment-options { "resources": "usable" }
 */

import { loadImage } from "../../lib/image";

describe("image", () => {

    test("can load image", async () => {

        const src = "https://codecapers.com.au/assets/img/profile.jpg";
        const image = await loadImage(src);
        expect(image.src).toBe(src);
    });

});