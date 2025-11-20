export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    setupFiles: ['<rootDir>/__mocks__/worker-global.js'],
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^serialize-error$': '<rootDir>/__mocks__/serialize-error.js'
    },
};

