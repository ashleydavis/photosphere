import { formatPicked } from "../lib/picked-paths";

describe("formatPicked", () => {
    test("a cancelled picker says nothing was chosen", () => {
        expect(formatPicked("Files", null)).toBe("Files: cancelled, nothing was chosen");
    });

    test("one folder is listed on its own line", () => {
        expect(formatPicked("Folder", "/home/me/photos")).toBe("Folder: 1 path\n  /home/me/photos");
    });

    test("several files are listed one to a line, with a count", () => {
        expect(formatPicked("Files", ["/a/one.jpg", "/a/two.jpg"])).toBe("Files: 2 paths\n  /a/one.jpg\n  /a/two.jpg");
    });

    test("paths with spaces and non-ASCII characters are shown as they are", () => {
        expect(formatPicked("Files", ["/a b/é 世界.jpg"])).toBe("Files: 1 path\n  /a b/é 世界.jpg");
    });

    test("an array holding one file is one path", () => {
        expect(formatPicked("Files", ["/only.txt"])).toBe("Files: 1 path\n  /only.txt");
    });
});
