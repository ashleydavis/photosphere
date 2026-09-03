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

//
// A file handed over as the body must reach the wire whenever the caller hands it over, exactly as a
// body written in bytes must.
//
// This is the same defect as above in the other half of the pair, and it was missed because the two
// halves were written apart. `write` sends straight to the transport once the head has gone;
// `writeFileBody` only recorded the file for `sendRequest` to send, and `sendRequest` had already
// run. The AWS SDK pipes a PutObject body after the head (it waits for the server's 100-continue
// first), so a photo uploaded from a phone went out as a PUT declaring its Content-Length over no
// body at all. The server then held its lock on the object waiting for bytes that were never coming
// and refused the upload with "A timeout occurred while trying to lock a resource, please reduce
// your request rate": measured against MinIO, about one photo in eight, each costing three attempts
// and a minute and a half of a sync that had nothing else wrong with it. Videos were never hit,
// because a multipart upload sends its parts as bytes through `write`.
//
describe("outbound request file body timing", () => {
    let filesSent: string[];

    beforeEach(() => {
        filesSent = [];
        (globalThis as any).host = {
            platform: "android",
            tcpConnect: () => JSON.stringify({ connectionId: "C-file" }),
            tcpWrite: (): null => null,
            tcpWriteFile: (_connectionId: string, path: string, offset: number, length: number): null => {
                filesSent.push(`${path}:${offset}:${length}`);
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
    async function flushMicrotasks(times: number): Promise<void> {
        for (let index = 0; index < times; index++) {
            await Promise.resolve();
        }
    }

    test("a file handed over before the head goes out reaches the wire", async () => {
        const outboundRequest: any = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "2700292" } });
        expect(outboundRequest.writeFileBody("/photos/one.jpg", 0, 2700292)).toBe(true);

        await flushMicrotasks(20);
        expect(filesSent).toEqual([ "/photos/one.jpg:0:2700292" ]);
    });

    test("a file handed over after the head goes out still reaches the wire", async () => {
        const outboundRequest: any = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "2700292" } });

        // A real tick, so the head has certainly gone before the file is handed over. This is the AWS
        // SDK's ordering when it pipes a PutObject body.
        await new Promise(resolve => globalThis.setTimeout(resolve, 5));
        expect(outboundRequest.writeFileBody("/photos/one.jpg", 0, 2700292)).toBe(true);

        await flushMicrotasks(20);
        expect(filesSent).toEqual([ "/photos/one.jpg:0:2700292" ]);
    });

    test("a file handed over after the head goes out is sent once, not twice", async () => {
        const outboundRequest: any = request({ hostname: "minio.test", port: 9000, path: "/obj", method: "PUT", headers: { "content-length": "2700292" } });

        await new Promise(resolve => globalThis.setTimeout(resolve, 5));
        outboundRequest.writeFileBody("/photos/one.jpg", 0, 2700292);

        await flushMicrotasks(20);
        expect(filesSent.length).toBe(1);
    });
});
