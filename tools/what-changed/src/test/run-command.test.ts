import * as os from "node:os";
import { runCommand, signalNumberFor } from "../lib/run-command";

test("runCommand resolves 0 for a command that succeeds", async () => {
    const code = await runCommand(["sh", "-c", "exit 0"], os.tmpdir());

    expect(code).toBe(0);
});

test("runCommand resolves the child's non-zero exit code", async () => {
    const code = await runCommand(["sh", "-c", "exit 7"], os.tmpdir());

    expect(code).toBe(7);
});

test("runCommand resolves 128 plus the signal number when the child is killed", async () => {
    //
    // A real signal death, not a simulated one: the shell kills itself with SIGTERM. Resolving 0 here
    // would let an interrupted run be recorded as a pass, which is why this path exists.
    //
    const code = await runCommand(["sh", "-c", "kill -TERM $$"], os.tmpdir());

    expect(code).toBe(143);
});

test("runCommand resolves 130 when the child is killed by SIGINT", async () => {
    const code = await runCommand(["sh", "-c", "kill -INT $$"], os.tmpdir());

    expect(code).toBe(130);
});

test("runCommand runs the command in the given working directory", async () => {
    //
    // Exits 0 only if the child's own working directory is the one that was asked for.
    //
    const code = await runCommand(["sh", "-c", `test "$(pwd -P)" = "$(cd ${os.tmpdir()} && pwd -P)"`], os.tmpdir());

    expect(code).toBe(0);
});

test("runCommand rejects with a clear error when the command does not exist", async () => {
    await expect(runCommand(["what-changed-no-such-command"], os.tmpdir()))
        .rejects.toThrow(/Failed to run "what-changed-no-such-command"/);
});

test("signalNumberFor maps the signals a child is realistically killed by", () => {
    expect(signalNumberFor("SIGHUP")).toBe(1);
    expect(signalNumberFor("SIGINT")).toBe(2);
    expect(signalNumberFor("SIGQUIT")).toBe(3);
    expect(signalNumberFor("SIGKILL")).toBe(9);
    expect(signalNumberFor("SIGTERM")).toBe(15);
});

test("signalNumberFor returns 0 for an unmapped signal, which still leaves a non-zero exit code", () => {
    expect(signalNumberFor("SIGWINCH")).toBe(0);
    expect(128 + signalNumberFor("SIGWINCH")).not.toBe(0);
});
