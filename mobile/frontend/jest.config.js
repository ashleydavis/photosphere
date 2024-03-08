/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
    preset: 'ts-jest',
    testEnvironment: 'jsdom',
    modulePathIgnorePatterns: [
        "dist",
        "build",
        "src/test/e2e",
    ],
};