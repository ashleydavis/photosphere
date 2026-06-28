//
// `child_process` shim for the embedded mobile worker.
//
// The media tools (`packages/tools`) and the desktop/CLI vault shell out via `child_process`. None
// of that runs on the mobile read path, but those modules import `child_process` at load time, so a
// shim must exist for the bundle to build. Every function throws the loud NOT IMPLEMENTED error if
// ever actually called, so a subprocess attempt on mobile fails visibly instead of silently.
//

//
// The platform string used in NOT IMPLEMENTED messages.
//
function hostPlatform(): string {
    const platform = (globalThis as any).host?.platform;
    return typeof platform === "string" ? platform : "mobile";
}

//
// Throws the verbatim NOT IMPLEMENTED error for a child_process function.
//
function notImplemented(name: string): never {
    throw new Error(`NOT IMPLEMENTED: native host function "${name}" is not implemented yet on ${hostPlatform()}. Implement it ASAP.`);
}

//
// Subprocesses are not available in the embedded engine; fails loudly.
//
export function exec(): never {
    notImplemented("childProcessExec");
}

//
// Subprocesses are not available in the embedded engine; fails loudly.
//
export function execSync(): never {
    notImplemented("childProcessExecSync");
}

//
// Subprocesses are not available in the embedded engine; fails loudly.
//
export function spawn(): never {
    notImplemented("childProcessSpawn");
}

//
// Subprocesses are not available in the embedded engine; fails loudly.
//
export function spawnSync(): never {
    notImplemented("childProcessSpawnSync");
}

//
// The default export mirrors `import childProcess from "child_process"`.
//
const childProcessModule = { exec, execSync, spawn, spawnSync };

export default childProcessModule;
