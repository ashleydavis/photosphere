export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    // jest's 5s default is real time, and this package's whole jest run crawls when a second copy of
    // the unit suite is running: `bun run test` starts a jest run per package at the same time, and
    // each one takes a worker per core, so two copies at once put several times the machine's cores
    // on it. Files that finish in seconds alone took 22s, 47s and 48s in that state, and
    // `runSyncWatch keeps syncing until it
    // is stopped`, whose own work is three iterations of a 1ms interval, was killed at 5s. The
    // budget was measuring the process's share of the machine rather than the test. Raised
    // package-wide, as packages/node-api and packages/encryption already do for the same reason.
    testTimeout: 30000,
    setupFiles: ['<rootDir>/__mocks__/worker-global.js'],
    setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^wrap-ansi$': '<rootDir>/__mocks__/wrap-ansi.js',
        '^is-unicode-supported$': '<rootDir>/__mocks__/is-unicode-supported.js',
        '^node-utils$': '<rootDir>/__mocks__/node-utils.js',
        '^utils$': '<rootDir>/__mocks__/utils.js',
        '^../lib/log$': '<rootDir>/__mocks__/log.js',
        '^./log$': '<rootDir>/__mocks__/log.js',
        '^./ensure-tools$': '<rootDir>/__mocks__/ensure-tools.js',
        '^./clack/prompts$': '<rootDir>/__mocks__/clack-prompts.js',
        '^./config$': '<rootDir>/__mocks__/config.js',
        '^tools$': '<rootDir>/__mocks__/tools.js',
        '^adb$': '<rootDir>/__mocks__/adb.js',
        '^../lib/terminal-utils$': '<rootDir>/__mocks__/terminal-utils.js',
        '^fs-extra$': '<rootDir>/__mocks__/fs-extra.js',
        '^serialize-error$': '<rootDir>/__mocks__/serialize-error.js'
    }
};