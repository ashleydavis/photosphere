import { Buffer } from "buffer";
import { createSocket, Socket, type IRemoteInfo } from "../../shims/node-dgram";

//
// Builds a mock native UDP host with jest mocks for each function.
//
function installHost(socketId: string, port: number) {
    const udpBind = jest.fn().mockReturnValue(JSON.stringify({ socketId, port }));
    const udpSend = jest.fn().mockReturnValue(null);
    const udpClose = jest.fn().mockReturnValue(null);
    (globalThis as any).host = { udpBind, udpSend, udpClose };
    return { udpBind, udpSend, udpClose };
}

//
// Pushes an inbound UDP event through the installed entry point.
//
function pushEvent(event: Record<string, unknown>): void {
    (globalThis as any).__udpEvent(JSON.stringify(event));
}

describe("dgram shim", () => {
    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("bind binds via udpBind on the wildcard with broadcast enabled and reports the bound port", () => {
        const host = installHost("U-bind", 54321);
        const socket = createSocket("udp4");
        socket.bind(54321);

        expect(host.udpBind).toHaveBeenCalledWith("0.0.0.0", 54321, true);
        expect(socket.address().port).toBe(54321);
    });

    test("bind(callback) fires the listening callback", async () => {
        installHost("U-cb", 1);
        const socket = createSocket("udp4");
        let listening = false;
        socket.bind(() => { listening = true; });

        await Promise.resolve();
        expect(listening).toBe(true);
    });

    test("an inbound message event emits a message with the decoded bytes and remote info", () => {
        installHost("U-msg", 1);
        const socket = createSocket("udp4");
        socket.bind(0);

        let payload: Buffer | undefined = undefined;
        let rinfo: IRemoteInfo | undefined = undefined;
        socket.on("message", (message: Buffer, remoteInfo: IRemoteInfo) => {
            payload = message;
            rinfo = remoteInfo;
        });

        pushEvent({ kind: "message", socketId: "U-msg", address: "192.168.0.9", port: 40000, base64: Buffer.from("PSIE_RECV:1:aa").toString("base64") });

        expect(payload!.toString()).toBe("PSIE_RECV:1:aa");
        expect(rinfo!.address).toBe("192.168.0.9");
        expect(rinfo!.port).toBe(40000);
    });

    test("send transmits the slice via udpSend with base64 bytes to the target host/port", () => {
        const host = installHost("U-send", 1);
        const socket = createSocket("udp4");
        socket.bind(0);

        const message = Buffer.from("PSIE_RECV:5555:ff");
        socket.send(message, 0, message.length, 54321, "255.255.255.255");

        expect(host.udpSend).toHaveBeenCalledWith("U-send", message.toString("base64"), "255.255.255.255", 54321);
    });

    test("setBroadcast is a no-op and does not throw", () => {
        installHost("U-bcast", 1);
        const socket = createSocket("udp4");
        socket.bind(0);
        expect(() => socket.setBroadcast(true)).not.toThrow();
    });

    test("close releases the native socket via udpClose and emits close", () => {
        const host = installHost("U-close", 1);
        const socket = createSocket("udp4");
        socket.bind(0);

        let closed = false;
        socket.on("close", () => { closed = true; });
        socket.close();

        expect(host.udpClose).toHaveBeenCalledWith("U-close");
        expect(closed).toBe(true);
    });

    test("createSocket accepts an options object and an inline message listener", () => {
        installHost("U-opts", 1);
        const received: string[] = [];
        const socket = createSocket({ type: "udp4", reuseAddr: true }, message => received.push(message.toString()));
        socket.bind(0);
        pushEvent({ kind: "message", socketId: "U-opts", address: "127.0.0.1", port: 1, base64: Buffer.from("hi").toString("base64") });
        expect(received).toEqual(["hi"]);
    });
});
