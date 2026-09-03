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
    // A test that imports a command reaches node-api, which reaches mime, which ships as ESM only.
    // The ts-jest preset transforms TypeScript alone and jest leaves node_modules alone by default,
    // so that package arrives as an untransformed `import` statement and jest refuses the whole
    // suite before a single test runs. Sending .js through ts-jest too, and exempting mime from the
    // node_modules exclusion, runs the real package rather than a stand-in for it. This is what
    // packages/vault already does for serialize-error.
    // Scoped to mime alone, not to every .js. The mocks in __mocks__ are already CommonJS and pass
    // through untransformed; sending them through ts-jest as well only produced a warning per file
    // per suite. allowJs lives here rather than in tsconfig.json so the build is not asked to
    // compile JavaScript it never compiles.
    transform: {
        '^.+\\.tsx?$': 'ts-jest',
        'node_modules[\\\\/]mime[\\\\/].+\\.js$': [ 'ts-jest', { tsconfig: { allowJs: true } } ],
    },
    transformIgnorePatterns: [
        "node_modules/(?!(mime)/)",
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