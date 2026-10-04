import { formatPingReply } from "../lib/format-reply";

describe("formatPingReply", () => {
    test("shows the Zig version, platform and the echoed greeting", () => {
        const text = formatPingReply({
            zigVersion: "0.16.0",
            os: "linux",
            arch: "x86_64",
            echo: { greeting: "hi" },
        });
        expect(text).toBe("Zig 0.16.0 on linux x86_64 says: hi");
    });
});
