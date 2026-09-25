//
// Port of packages/config (src/index.ts): the version and build metadata of the CLI.
// There is no config-zig package, so the two constants live here.
//

//
// The build metadata of the CLI (TypeScript: `buildMetadata`).
//
pub const IBuildMetadata = struct {
    // The commit the CLI was built from.
    commitHash: []const u8,

    // When the CLI was built.
    buildDate: []const u8,

    // True for nightly builds.
    isNightly: bool,
};

// Version is set by the CI build process. "dev" is used for local development.
pub const version = "dev";

// Build metadata is set by the CI build process.
pub const buildMetadata: IBuildMetadata = .{
    .commitHash = "dev",
    .buildDate = "development",
    .isNightly = false,
};
