//
// The version and build metadata of the app.
//

//
// The build metadata.
//
pub const IBuildMetadata = struct {
    // The commit the app was built from.
    commitHash: []const u8,

    // When the app was built.
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
