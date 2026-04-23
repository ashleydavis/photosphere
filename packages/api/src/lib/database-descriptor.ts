
//
// Descriptor passed to workers identifying the database to operate on.
// Workers receive only what they cannot derive themselves — the path and
// an optional unresolved encryption key name from the -k CLI flag.
// All credentials (S3, encryption PEMs, geocoding) are resolved by the
// worker itself via resolveStorageCredentials.
//
export interface IDatabaseDescriptor {
    //
    // Storage location string (e.g. "fs:/path/to/db" or "s3:bucket:/path").
    //
    databasePath: string;

    //
    // Optional unresolved encryption key identifier from the -k CLI flag.
    // May be a filesystem path to a PEM file or a vault secret name.
    // Absent when the user did not supply -k.
    //
    encryptionKey?: string;
}
