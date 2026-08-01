//
// Prints a TCP port the OS says is free, by binding port 0 on the loopback interface and reading
// back the port the OS assigned.
//
// There is no shell answer to this: binding a socket needs a socket API. A hardcoded number is not an
// answer either, because several smoke suites run at once out of one checkout and would fight over
// the same port.
//
// Usage: bun scripts/find-free-port.ts
//

import { createServer } from "node:net";

//
// Binds an OS-assigned port on loopback, prints it, and releases it.
//
async function printFreePort(): Promise<void> {
    const probe = createServer();
    await new Promise<void>((resolve, reject) => {
        probe.once("error", reject);
        probe.listen(0, "127.0.0.1", resolve);
    });

    const address = probe.address();
    if (address === null || typeof address === "string") {
        throw new Error("The probe socket reported no numeric address, so no free port could be chosen.");
    }
    console.log(address.port);

    await new Promise<void>(resolve => {
        probe.close(() => resolve());
    });
}

await printFreePort();
