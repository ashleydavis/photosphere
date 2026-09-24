//
// Timeout for retrying operations that stream large files (e.g. videos) to/from S3.
//
pub const LARGE_FILE_TIMEOUT: u64 = 90 * 60 * 1_000;
