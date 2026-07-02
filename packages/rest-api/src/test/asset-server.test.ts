import { createServer } from "http";
import type { AddressInfo } from "net";

// ── module mocks ─────────────────────────────────────────────────────────────
//
// createAssetServer imports the node-api barrel (which pulls in ESM-only and native deps) and the
// utils package. For a binding assertion we only need a real HTTP server, so the serving core and
// routes are stubbed out and utils is reduced to the values createAssetServer actually reads.
//

jest.mock("node-api", () => ({
    createAssetServerCore: jest.fn(() => ({})),
    attachAssetServerRoutes: jest.fn(),
}));

jest.mock("utils", () => ({
    log: { info: jest.fn(), error: jest.fn(), exception: jest.fn(), verbose: jest.fn() },
}));

import { createAssetServer } from "../lib/asset-server";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Grabs a free TCP port by briefly binding an ephemeral loopback server and reading its port.
//
function getFreePort(): Promise<number> {
    return new Promise<number>((resolve, reject) => {
        const probe = createServer();
        probe.once("error", reject);
        probe.listen(0, "127.0.0.1", () => {
            const address = probe.address() as AddressInfo;
            const port = address.port;
            probe.close(() => resolve(port));
        });
    });
}

//
// Minimal stubs for the generators createAssetServer forwards to the (mocked) core.
//
const stubUuidGenerator: IUuidGenerator = { generate: () => "uuid-1" };
const stubTimestampProvider: ITimestampProvider = { now: () => 0, dateNow: () => new Date(0) };

describe("createAssetServer", () => {

    test("binds only to the loopback interface", async () => {
        const port = await getFreePort();
        const result = await createAssetServer({
            port,
            uuidGenerator: stubUuidGenerator,
            timestampProvider: stubTimestampProvider,
            sessionId: "test-session",
        });

        expect(result.server).toBeDefined();
        const address = result.server!.address() as AddressInfo;
        expect(address.address).toBe("127.0.0.1");
        expect(address.port).toBe(port);

        await new Promise<void>(resolve => result.server!.close(() => resolve()));
    });
});
