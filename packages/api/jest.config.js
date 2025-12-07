export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^mime$': '<rootDir>/__mocks__/mime.js',
    },
};