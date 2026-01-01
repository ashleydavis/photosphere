export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
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