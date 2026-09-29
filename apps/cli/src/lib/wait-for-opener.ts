import { ChildProcess } from "child_process";

//
// Waits for the process started to open a URL (the one the `open` package returns) to finish, so the
// CLI does not exit while it is still running. Needed on Windows, where the `open` package starts
// PowerShell without `detached`, and libuv puts a child that is not detached in a job object that
// kills it when the parent exits: `psi bug` exited straight after starting PowerShell, which was
// killed before it could start the browser. PowerShell's `Start` returns once the browser is started,
// so the wait is short. Returns at once when the opener could not be started at all (it has no pid),
// or has already finished.
//
export async function waitForOpener(opener: ChildProcess): Promise<void> {
    if (opener.pid === undefined) {
        return;
    }

    if (opener.exitCode !== null || opener.signalCode !== null) {
        return;
    }

    await new Promise<void>(resolve => {
        opener.once("exit", () => {
            resolve();
        });
        opener.once("error", () => {
            resolve();
        });
    });
}
