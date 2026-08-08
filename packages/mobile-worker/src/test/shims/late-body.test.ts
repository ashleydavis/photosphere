import { Buffer } from "buffer";
import { request } from "../../shims/node-http";

//
// A request body must reach the wire whenever the caller writes it, not only if it was written
// before the head went out.
//
// The head is written on a fixed chain of microtasks from the constructor rather than when the
// caller says it has finished, so anything written later used to be pushed onto a list that nothing
// read again. The request went out carrying the caller's own Content-Length header over an empty
// body, and the server waited for bytes that were never coming.
//
// That is a request that never completes and never fails. The AWS SDK writes a PutObject body
// through a stream, so its chunks land after the head: on a device, creating a database on S3 hung
// with nothing in the log, while every GET over the same transport worked because a GET has no body
// for the timing to lose. It is Android smoke test 41.
//
describe("outbound request body timing", () => {
    let writes: Buffer[];

    beforeEach(() => {
        writes = [];
        (globalThis as any).host = {
            platform: "android",
            tcpConnect: () => JSON.stringify({ connectionId: "C-out" }),
            tcpWrite: (_connectionId: string, base64: string): null => {
                writes.push(Buffer.from(base64, "base64"));
                return null;
            },
            tcpClose: (): null => null,
        };
    });

    afterEach(() => {
        delete (globalThis as any).host;
    });

    //
    // Drains pending microtasks, which is when the head is written.
    //
    async function flush(times: number): Promise<void> {
        for (let index = 0; index < times; index++) {
            await Promise.resolve();
        }
    }

    //
    // What everything on the wire adds up to.
    //
    function sent(): string {
        return Buffer.concat(writes).toString("utf8");
    }

    test("a body written before the head goes out reaches the wire", async () => {
        const req = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "7" } });
        req.write(Buffer.from("payload"));

        await flush(20);
        expect(sent()).toContain("payload");
    });

    test("a body written after the head goes out still reaches the wire", async () => {
        const req = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "7" } });

        // A real tick, so the head has certainly gone before the body is written. This is the AWS
        // SDK's ordering when it streams a PutObject body.
        await new Promise(resolve => globalThis.setTimeout(resolve, 5));
        req.write(Buffer.from("payload"));

        await flush(20);
        expect(sent()).toContain("payload");
    });

    test("the body follows the head rather than being spliced into it", async () => {
        const req = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "7" } });

        await new Promise(resolve => globalThis.setTimeout(resolve, 5));
        req.write(Buffer.from("payload"));
        await flush(20);

        const wire = sent();
        // The blank line ends the head, and the body must come after it, which is what lets the
        // server read exactly the Content-Length bytes it was promised.
        expect(wire.indexOf("payload")).toBeGreaterThan(wire.indexOf("\r\n\r\n"));
    });
});
