export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^serialize-error$': '<rootDir>/__mocks__/serialize-error.js'
    },
};

