import os, { tmpdir, homedir, platform, release, EOL } from "../../shims/node-os";

//
// Unit tests for the os shim. The values are sandbox-relative so derived config paths stay inside
// the native storage root.
//
describe("node-os shim", () => {

    test("tmpdir returns a sandbox-relative temp directory name", () => {
        expect(tmpdir()).toBe("tmp");
    });

    test("homedir returns an empty string so derived paths stay relative", () => {
        expect(homedir()).toBe("");
    });

    test("platform returns android", () => {
        expect(platform()).toBe("android");
    });

    test("release returns a non-empty string, which is all the AWS SDK's user-agent needs", () => {
        expect(typeof release()).toBe("string");
        expect(release().length).toBeGreaterThan(0);
    });

    test("EOL is a newline and the default export carries the functions", () => {
        expect(EOL).toBe("\n");
        expect(os.tmpdir()).toBe("tmp");
        expect(os.homedir()).toBe("");
        expect(os.release()).toBe(release());
    });
});
