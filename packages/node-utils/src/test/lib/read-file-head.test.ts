import * as fs from "fs/promises";
import * as path from "path";
import { readFileHead, remove } from "../../lib/fs";
import { createTestTempDir } from "../../lib/test-temp-dir";

//
// Reading the head of a file rather than all of it.
//
// This is what lets a photo's EXIF be read without the whole photo crossing the mobile engine
// bridge, where every byte becomes part of a base64 string built natively and decoded in the engine.
//

describe("readFileHead", () => {
    let tempDir: string;

    beforeEach(() => {
        tempDir = createTestTempDir("temp-test-read-file-head");
    });

    afterEach(async () => {
        await remove(tempDir);
    });

    test("reads only the first bytes of a longer file", async () => {
        const contents = Buffer.alloc(1024 * 1024);
        for (let index = 0; index < contents.length; index++) {
            contents[index] = index % 251;
        }
        const filePath = path.join(tempDir, "long.bin");
        await fs.writeFile(filePath, contents);

        const head = await readFileHead(filePath, 4096);

        expect(head.length).toBe(4096);
        expect(head.equals(contents.subarray(0, 4096))).toBe(true);
    });

    test("reads the whole of a file shorter than the count asked for", async () => {
        const contents = Buffer.from("short", "utf8");
        const filePath = path.join(tempDir, "short.bin");
        await fs.writeFile(filePath, contents);

        const head = await readFileHead(filePath, 4096);

        expect(head.equals(contents)).toBe(true);
    });

    test("reads nothing from an empty file rather than failing", async () => {
        const filePath = path.join(tempDir, "empty.bin");
        await fs.writeFile(filePath, Buffer.alloc(0));

        expect((await readFileHead(filePath, 4096)).length).toBe(0);
    });
});
