import { gzipSync as nodeGzipSync, gunzipSync as nodeGunzipSync } from "zlib";
import { gzipSync, gunzipSync } from "../../shims/node-zlib";

//
// Unit tests for the zlib shim. The merkle-tree reader gunzips compressed payloads on the read
// path, so gunzip correctness (including interop with Node's gzip) is the key property.
//
describe("node-zlib shim", () => {

    test("gzipSync then gunzipSync round-trips the original bytes", () => {
        const original = Buffer.from("the quick brown fox jumps over the lazy dog".repeat(50), "utf8");
        const restored = gunzipSync(gzipSync(original));
        expect(restored.equals(original)).toBe(true);
    });

    test("gunzipSync decompresses data produced by Node's gzipSync", () => {
        const original = Buffer.from([5, 4, 3, 2, 1, 0, 255, 254, 253]);
        const restored = gunzipSync(nodeGzipSync(original));
        expect(restored.equals(original)).toBe(true);
    });

    test("Node's gunzipSync decompresses data produced by the shim's gzipSync", () => {
        const original = Buffer.from("interop check", "utf8");
        const restored = nodeGunzipSync(gzipSync(original));
        expect(restored.equals(original)).toBe(true);
    });

    test("gzipSync honours an explicit compression level", () => {
        const original = Buffer.from("compressible ".repeat(100), "utf8");
        const restored = gunzipSync(gzipSync(original, { level: 9 }));
        expect(restored.equals(original)).toBe(true);
    });

    test("gzipSync returns a Buffer", () => {
        expect(Buffer.isBuffer(gzipSync(Buffer.from("x")))).toBe(true);
    });
});
