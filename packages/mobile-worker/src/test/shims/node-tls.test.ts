import { Buffer } from "buffer";
import { connect, connectClient, createServer, installTlsInbound, Server, TLSSocket } from "../../shims/node-tls";

//
// Builds a mock native TLS host with jest mocks for each function.
//
function installHost(ids: { listenerId: string; port: number; connectionId: string; peerCertBase64: string }) {
    const tlsListen = jest.fn().mockReturnValue(JSON.stringify({ listenerId: ids.listenerId, port: ids.port }));
    const tlsConnect = jest.fn().mockReturnValue(JSON.stringify({ connectionId: ids.connectionId, peerCertBase64: ids.peerCertBase64 }));
    const tlsWrite = jest.fn().mockReturnValue(null);
    const tlsClose = jest.fn().mockReturnValue(null);
    const tlsStopListening = jest.fn().mockReturnValue(null);
    (globalThis as any).host = { tlsListen, tlsConnect, tlsWrite, tlsClose, tlsStopListening };
    return { tlsListen, tlsConnect, tlsWrite, tlsClose, tlsStopListening };
}

//
// Pushes an inbound TLS event through the installed entry point.
//
function pushEvent(event: Record<string, unknown>): void {
    (globalThis as any).__tlsEvent(JSON.stringify(event));
}

describe("tls shim", () => {
    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("connect calls tlsConnect, emits secureConnect, and exposes the peer certificate raw bytes", async () => {
        const certDer = Buffer.from("fake-cert-der");
        const host = installHost({ listenerId: "L", port: 1, connectionId: "TC-1", peerCertBase64: certDer.toString("base64") });

        const socket = connect(4433, "127.0.0.1");
        expect(host.tlsConnect).toHaveBeenCalledWith("127.0.0.1", 4433, true);

        let secured = false;
        socket.on("secureConnect", () => { secured = true; });
        await Promise.resolve();
        expect(secured).toBe(true);

        expect(socket.getPeerCertificate().raw.equals(certDer)).toBe(true);
    });

    test("Server.listen binds via tlsListen with cert and key", () => {
        const host = installHost({ listenerId: "L-listen", port: 8443, connectionId: "C", peerCertBase64: "" });
        const server = createServer({ key: "KEYPEM", cert: "CERTPEM" });
        server.listen(0, "127.0.0.1");

        expect(host.tlsListen).toHaveBeenCalledWith("127.0.0.1", 0, "CERTPEM", "KEYPEM");
        expect(server.address().port).toBe(8443);
    });

    test("an inbound connection event emits a secureConnection TLSSocket", () => {
        installHost({ listenerId: "L-conn", port: 1, connectionId: "C", peerCertBase64: "" });
        const server = new Server("CERT", "KEY");
        server.listen(0);

        let received: TLSSocket | undefined = undefined;
        server.on("secureConnection", socket => { received = socket; });
        pushEvent({ kind: "connection", listenerId: "L-conn", connectionId: "SC-1" });

        expect(received).toBeInstanceOf(TLSSocket);
        expect(received!.connectionId).toBe("SC-1");
    });

    test("inbound data emits decoded bytes and write/end call tlsWrite/tlsClose", () => {
        const host = installHost({ listenerId: "L-io", port: 1, connectionId: "C", peerCertBase64: "" });
        const server = new Server("CERT", "KEY");
        server.listen(0);
        let socket: TLSSocket | undefined = undefined;
        server.on("secureConnection", accepted => { socket = accepted; });
        pushEvent({ kind: "connection", listenerId: "L-io", connectionId: "SC-2" });

        const chunks: Buffer[] = [];
        socket!.on("data", chunk => chunks.push(chunk));
        pushEvent({ kind: "data", connectionId: "SC-2", base64: Buffer.from("GET / HTTP/1.1").toString("base64") });
        expect(Buffer.concat(chunks).toString()).toBe("GET / HTTP/1.1");

        socket!.end(Buffer.from("response"));
        expect(host.tlsWrite).toHaveBeenCalledWith("SC-2", Buffer.from("response").toString("base64"));
        expect(host.tlsClose).toHaveBeenCalledWith("SC-2");
    });

    test("an inbound close event emits end then close", () => {
        installHost({ listenerId: "L-close", port: 1, connectionId: "TC-c", peerCertBase64: "" });
        const socket = connect(4433, "127.0.0.1");

        const events: string[] = [];
        socket.on("end", () => events.push("end"));
        socket.on("close", () => events.push("close"));
        pushEvent({ kind: "close", connectionId: "TC-c" });

        expect(events).toEqual(["end", "close"]);
    });

    test("server.close stops the listener via tlsStopListening", () => {
        const host = installHost({ listenerId: "L-stop", port: 1, connectionId: "C", peerCertBase64: "" });
        const server = new Server("CERT", "KEY");
        server.listen(0);
        server.close();
        expect(host.tlsStopListening).toHaveBeenCalledWith("L-stop");
    });

    test("connectClient passes the caller's trust choice through to native", () => {
        const host = installHost({ listenerId: "L-cc", port: 4433, connectionId: "C-cc", peerCertBase64: "" });

        const socket = connectClient(4433, "127.0.0.1", true);

        expect(host.tlsConnect).toHaveBeenCalledWith("127.0.0.1", 4433, true);
        expect(socket).toBeInstanceOf(TLSSocket);
    });

    test("connectClient asks native to skip validation only when told to", () => {
        const host = installHost({ listenerId: "L-cu", port: 4433, connectionId: "C-cu", peerCertBase64: "" });

        connectClient(4433, "127.0.0.1", false);

        expect(host.tlsConnect).toHaveBeenCalledWith("127.0.0.1", 4433, false);
    });

    test("connect validates by default, matching Node", () => {
        const host = installHost({ listenerId: "L-cd", port: 4433, connectionId: "C-cd", peerCertBase64: "" });

        connect(4433, "127.0.0.1");

        expect(host.tlsConnect).toHaveBeenCalledWith("127.0.0.1", 4433, true);
    });

    test("connect skips validation when the caller passes rejectUnauthorized false", () => {
        const host = installHost({ listenerId: "L-cn", port: 4433, connectionId: "C-cn", peerCertBase64: "" });

        connect(4433, "127.0.0.1", { rejectUnauthorized: false });

        expect(host.tlsConnect).toHaveBeenCalledWith("127.0.0.1", 4433, false);
    });

    test("connectClient does not schedule secureConnect, leaving that timing to the caller", async () => {
        installHost({ listenerId: "L-cp", port: 4433, connectionId: "C-cp", peerCertBase64: "" });

        const socket = connectClient(4433, "127.0.0.1", true);
        let handshakeSeen = false;
        socket.on("secureConnect", () => { handshakeSeen = true; });
        await Promise.resolve();
        await Promise.resolve();

        expect(handshakeSeen).toBe(false);
    });

    test("installTlsInbound installs the native event entry point on the given scope", () => {
        const scope: any = {};

        installTlsInbound(scope);

        expect(typeof scope.__tlsEvent).toBe("function");
        // An event for a connection that no longer exists is ignored rather than throwing.
        expect(() => scope.__tlsEvent(JSON.stringify({ kind: "data", connectionId: "gone", base64: "" }))).not.toThrow();
    });
});
