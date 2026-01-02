export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^mime$': '<rootDir>/__mocks__/mime.js',
        '^serialize-error$': '<rootDir>/__mocks__/serialize-error.js'
    }
};