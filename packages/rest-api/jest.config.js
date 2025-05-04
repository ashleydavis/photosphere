export default {
    preset: 'ts-jest',
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