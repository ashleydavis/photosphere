import { Buffer } from "buffer";
import { createServer, Server, Socket } from "../../shims/node-net";

//
// Builds a mock native TCP host with jest mocks for each function.
//
function installHost(listenerId: string, port: number) {
    const tcpListen = jest.fn().mockReturnValue(JSON.stringify({ listenerId, port }));
    const tcpWrite = jest.fn().mockReturnValue(null);
    const tcpClose = jest.fn().mockReturnValue(null);
    const tcpStopListening = jest.fn().mockReturnValue(null);
    (globalThis as any).host = { tcpListen, tcpWrite, tcpClose, tcpStopListening };
    return { tcpListen, tcpWrite, tcpClose, tcpStopListening };
}

//
// Pushes an inbound TCP event through the installed entry point.
//
function pushEvent(event: Record<string, unknown>): void {
    (globalThis as any).__tcpEvent(JSON.stringify(event));
}

describe("net shim", () => {
    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("listen binds via tcpListen and reports the bound port", () => {
        const host = installHost("L-listen", 4321);
        const server = createServer();
        server.listen(0, "127.0.0.1");

        expect(host.tcpListen).toHaveBeenCalledWith("127.0.0.1", 0);
        expect(server.address().port).toBe(4321);
    });

    test("an inbound connection event emits a Socket", () => {
        installHost("L-conn", 1);
        const server = new Server();
        server.listen(0);

        let received: Socket | undefined = undefined;
        server.on("connection", socket => { received = socket; });

        pushEvent({ kind: "connection", listenerId: "L-conn", connectionId: "C-1" });

        expect(received).toBeInstanceOf(Socket);
        expect(received!.connectionId).toBe("C-1");
    });

    test("inbound data emits a data event with the decoded bytes", () => {
        installHost("L-data", 1);
        const server = new Server();
        server.listen(0);
        let socket: Socket | undefined = undefined;
        server.on("connection", accepted => { socket = accepted; });
        pushEvent({ kind: "connection", listenerId: "L-data", connectionId: "C-2" });

        const chunks: Buffer[] = [];
        socket!.on("data", chunk => chunks.push(chunk));
        pushEvent({ kind: "data", connectionId: "C-2", base64: Buffer.from("hello").toString("base64") });

        expect(Buffer.concat(chunks).toString()).toBe("hello");
    });

    test("socket.write calls tcpWrite with base64 bytes", () => {
        const host = installHost("L-write", 1);
        const server = new Server();
        server.listen(0);
        let socket: Socket | undefined = undefined;
        server.on("connection", accepted => { socket = accepted; });
        pushEvent({ kind: "connection", listenerId: "L-write", connectionId: "C-3" });

        socket!.write(Buffer.from("world"));

        expect(host.tcpWrite).toHaveBeenCalledWith("C-3", Buffer.from("world").toString("base64"));
    });

    test("socket.end writes the final chunk then closes via tcpClose", () => {
        const host = installHost("L-end", 1);
        const server = new Server();
        server.listen(0);
        let socket: Socket | undefined = undefined;
        server.on("connection", accepted => { socket = accepted; });
        pushEvent({ kind: "connection", listenerId: "L-end", connectionId: "C-4" });

        socket!.end(Buffer.from("bye"));

        expect(host.tcpWrite).toHaveBeenCalledWith("C-4", Buffer.from("bye").toString("base64"));
        expect(host.tcpClose).toHaveBeenCalledWith("C-4");
    });

    test("an inbound close event emits end then close", () => {
        installHost("L-close", 1);
        const server = new Server();
        server.listen(0);
        let socket: Socket | undefined = undefined;
        server.on("connection", accepted => { socket = accepted; });
        pushEvent({ kind: "connection", listenerId: "L-close", connectionId: "C-5" });

        const events: string[] = [];
        socket!.on("end", () => events.push("end"));
        socket!.on("close", () => events.push("close"));
        pushEvent({ kind: "close", connectionId: "C-5" });

        expect(events).toEqual(["end", "close"]);
    });

    test("server.close stops the listener via tcpStopListening", () => {
        const host = installHost("L-stop", 1);
        const server = new Server();
        server.listen(0);

        server.close();

        expect(host.tcpStopListening).toHaveBeenCalledWith("L-stop");
    });
});
