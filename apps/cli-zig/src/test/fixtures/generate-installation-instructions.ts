//
// Generates the Windows and macOS installation-instructions fixtures (installation-instructions-win32.json and
// installation-instructions-darwin.json) from the TypeScript implementation, with os.platform() mocked.
// The Linux fixture (installation-instructions.json) comes from generate.ts.
// Run from the repo root: FORCE_COLOR=1 bun run apps/cli-zig/src/test/fixtures/generate-installation-instructions.ts
//
import { mock } from "bun:test";
import { writeFileSync } from "fs";
import { join } from "path";
import * as realOs from "os";

const fixturesDir = import.meta.dir;

//
// The platform that the mocked os.platform() returns.
//
let mockedPlatform = "linux";
mock.module("os", () => ({ ...realOs, platform: () => mockedPlatform }));
const { showInstallationInstructions } = await import("../../../../cli/src/lib/installation-instructions");

for (const platform of ["win32", "darwin"]) {
    mockedPlatform = platform;
    const installationCases: any[] = [];
    for (const missingTools of [["ImageMagick"], ["ffmpeg"], ["ffprobe"], ["ImageMagick", "ffprobe", "ffmpeg"], []]) {
        const lines: string[] = [];
        const originalLog = console.log;
        console.log = (message: string) => { lines.push(message); };
        showInstallationInstructions(missingTools);
        console.log = originalLog;
        installationCases.push({ missingTools, output: lines.join("\n") + "\n" });
    }
    writeFileSync(join(fixturesDir, `installation-instructions-${platform}.json`), JSON.stringify(installationCases, null, 4) + "\n");
}
