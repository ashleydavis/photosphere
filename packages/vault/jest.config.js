export default {
    preset: 'ts-jest',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    // node-utils reaches serialize-error, which ships as ESM only. The ts-jest preset transforms
    // TypeScript alone and jest leaves node_modules alone by default, so that package arrives as
    // an untransformed `import` statement and jest refuses it. Sending .js through ts-jest too,
    // and exempting the two files that make up the package from the node_modules exclusion, runs
    // the real package rather than a stand-in for it.
    transform: {
        '^.+\\.tsx?$': 'ts-jest',
        '^.+\\.jsx?$': 'ts-jest',
    },
    transformIgnorePatterns: [
        "node_modules/(?!(serialize-error|error-constructors)/)",
    ],
};
