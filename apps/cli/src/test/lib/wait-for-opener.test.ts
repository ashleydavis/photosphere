import { spawn, ChildProcess } from "child_process";
import { waitForOpener } from "../../lib/wait-for-opener";

//
// Waits for the given child process to exit.
//
function waitForExit(child: ChildProcess): Promise<void> {
    return new Promise<void>(resolve => {
        child.once("exit", () => {
            resolve();
        });
    });
}

describe("waitForOpener", () => {
    test("waits until the opener has exited", async () => {
        const opener = spawn(process.execPath, ["-e", "setTimeout(() => {}, 300)"]);
        await waitForOpener(opener);
        expect(opener.exitCode).toBe(0);
    });

    test("returns when the opener could not be started", async () => {
        const opener = spawn("photosphere-no-such-opener-command", []);
        opener.on("error", () => {
            // The spawn failure is expected.
        });
        await waitForOpener(opener);
        expect(opener.pid).toBeUndefined();
    });

    test("returns when the opener has already exited", async () => {
        const opener = spawn(process.execPath, ["-e", ""]);
        await waitForExit(opener);
        await waitForOpener(opener);
        expect(opener.exitCode).toBe(0);
    });
});
