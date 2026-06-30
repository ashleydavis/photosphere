//
// Shared test helper: a mock native TCP host plus a one-request HTTP round-trip driver.
//
// The net/http shims read `globalThis.host` for the native TCP functions and receive inbound events
// via `globalThis.__tcpEvent`. This helper installs a mock host that captures outbound writes and
// resolves when a connection is closed, and drives a single request/response through the shimmed
// server so tests can assert on the raw response bytes.
//

import { Buffer } from "buffer";

//
// A mock native TCP host whose four functions are jest mocks, plus per-connection write capture.
//
export interface IMockTcpHost {
    // The host object to assign to globalThis.host.
    host: Record<string, unknown>;

    // Captured outbound write buffers keyed by connection id.
    writes: Map<string, Buffer[]>;

    // Resolves (per connection id) once that connection has been closed via tcpClose.
    closed: Map<string, Promise<void>>;

    // The listener id tcpListen hands back.
    listenerId: string;

    // The port tcpListen reports as bound.
    port: number;
}

//
// Installs a mock TCP host on globalThis.host that records writes and signals connection closes.
// tcpListen always reports the given listenerId/port.
//
export function installMockTcpHost(listenerId: string, port: number): IMockTcpHost {
    const writes = new Map<string, Buffer[]>();
    const closed = new Map<string, Promise<void>>();
    const closeResolvers = new Map<string, () => void>();

    const ensureClosePromise = (connectionId: string): void => {
        if (!closed.has(connectionId)) {
            closed.set(connectionId, new Promise<void>(resolve => {
                closeResolvers.set(connectionId, resolve);
            }));
        }
    };

    const host = {
        sessionId: "test-session",
        platform: "android",
        tcpListen: (_host: string, _port: number): string => {
            return JSON.stringify({ listenerId, port });
        },
        tcpWrite: (connectionId: string, base64: string): null => {
            const existing = writes.get(connectionId) || [];
            existing.push(Buffer.from(base64, "base64"));
            writes.set(connectionId, existing);
            return null;
        },
        tcpClose: (connectionId: string): null => {
            ensureClosePromise(connectionId);
            const resolver = closeResolvers.get(connectionId);
            if (resolver) {
                resolver();
            }
            return null;
        },
        tcpStopListening: (_listenerId: string): null => {
            return null;
        },
    };

    // Pre-create the close promise so callers can await it even before the close fires.
    ensureClosePromise("C1");

    (globalThis as any).host = host;

    return { host, writes, closed, listenerId, port };
}

//
// Removes the mock host so it does not leak across tests.
//
export function uninstallMockTcpHost(): void {
    delete (globalThis as any).host;
}

//
// Pushes one inbound TCP event into the engine via the installed __tcpEvent entry point.
//
export function pushTcpEvent(event: Record<string, unknown>): void {
    (globalThis as any).__tcpEvent(JSON.stringify(event));
}

//
// Drives a single request through the shimmed server on connection "C1": delivers the raw request
// bytes, waits for the response to be written and the connection closed, then returns the full
// response bytes.
//
export async function roundTripRequest(mock: IMockTcpHost, requestBytes: Buffer): Promise<Buffer> {
    pushTcpEvent({ kind: "connection", listenerId: mock.listenerId, connectionId: "C1" });
    pushTcpEvent({ kind: "data", connectionId: "C1", base64: requestBytes.toString("base64") });

    await mock.closed.get("C1");

    const buffers = mock.writes.get("C1") || [];
    return Buffer.concat(buffers);
}
