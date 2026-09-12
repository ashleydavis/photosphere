import { Buffer } from "buffer";
import { request } from "../../shims/node-http";

//
// A request that sends a different number of body bytes from the number its head declared must say
// so, in a line naming both.
//
// Nothing else can. The server is the only other party holding both numbers and all it can do is
// wait for bytes that are not coming: MinIO gives up after thirty seconds and answers "A timeout
// occurred while trying to lock a resource, please reduce your request rate", which describes a busy
// server and sends whoever reads it to look at load, request rates and locks. Measured on a Pixel 6
// syncing to MinIO on the same LAN, every thumbnail push failed that way, three attempts each, a
// minute and a half a file, with the server idle throughout.
//
describe("a request body that does not match its Content-Length", () => {
    let warnings: string[];
    let transport: any;
    let warnNormally: (...args: any[]) => void;

    beforeEach(() => {
        warnings = [];
        warnNormally = console.warn;
        console.warn = (message: string) => {
            warnings.push(message);
        };
        (globalThis as any).host = {
            platform: "android",
            tcpConnect: () => JSON.stringify({ connectionId: "C-mismatch" }),
            tcpWrite: (): null => null,
            tcpWriteFile: (): null => null,
            tcpClose: (): null => null,
        };
    });

    afterEach(() => {
        console.warn = warnNormally;
        delete (globalThis as any).host;
    });

    //
    // Makes a PUT declaring the given Content-Length and keeps hold of its transport, so a response
    // can be fed back the way the host's inbound dispatcher feeds one.
    //
    function putDeclaring(contentLength: number): any {
        const outboundRequest: any = request({
            hostname: "minio.test",
            port: 9000,
            path: "/bucket/thumb/one",
            method: "PUT",
            headers: {
                "content-length": String(contentLength),
            },
        });
        outboundRequest.on("socket", (socket: any) => {
            transport = socket;
        });
        return outboundRequest;
    }

    //
    // Answers the request, which is when the head is compared with what was sent.
    //
    function answer(): void {
        transport.deliverData(Buffer.from("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "utf8").toString("base64"));
    }

    //
    // Drains pending microtasks, which is when the head is written.
    //
    async function flushMicrotasks(times: number): Promise<void> {
        for (let index = 0; index < times; index++) {
            await Promise.resolve();
        }
    }

    test("a body shorter than the head promised is reported, with both numbers", async () => {
        const outboundRequest = putDeclaring(24028);
        await flushMicrotasks(20);

        outboundRequest.write(Buffer.from("only a little"));
        answer();

        expect(warnings.join("\n")).toContain("declared 24028 body bytes and sent 13");
    });

    test("a file body of the length promised is not reported", async () => {
        const outboundRequest = putDeclaring(24028);
        await flushMicrotasks(20);

        outboundRequest.writeFileBody("/db/thumb/one", 0, 24028);
        answer();

        expect(warnings).toEqual([]);
    });

    test("a body written in pieces that add up to the length promised is not reported", async () => {
        const outboundRequest = putDeclaring(10);
        await flushMicrotasks(20);

        outboundRequest.write(Buffer.from("12345"));
        outboundRequest.write(Buffer.from("67890"));
        answer();

        expect(warnings).toEqual([]);
    });

    test("a request sending no body at all against a stated length is reported", async () => {
        putDeclaring(2700292);
        await flushMicrotasks(20);

        answer();

        expect(warnings.join("\n")).toContain("declared 2700292 body bytes and sent 0");
    });
});
