export default {
    preset: 'ts-jest',
    // jest's 5s default is real time, and this package's whole jest run crawls when a second copy of
    // the unit suite is running: `bun run test` starts a jest run per package at the same time, and
    // each one takes a worker per core, so two copies at once put several times the machine's cores
    // on it. `waitForElement waits
    // for the nth element when several share a data-id` was killed at 5s in that state; it drives a
    // hand-wound clock and takes 5ms on an idle machine, so the budget was measuring the process's
    // share of the machine rather than the test. Raised package-wide, as packages/node-api and
    // packages/encryption already do for the same reason.
    testTimeout: 30000,
    //
    // This would allow the image tests to work, except jsdom depends on
    // the canvas shim which I can't get to install on Ubuntu.
    //
    // testEnvironment: 'jsdom',
    modulePathIgnorePatterns: [
        "dist",
        "build",
        "src/test/e2e",
    ],
};