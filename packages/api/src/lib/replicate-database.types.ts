//
// Input data for the replicate-database background task.
//
export interface IReplicateDatabaseData {
    //
    // The source database path. When the path is registered in databases.json its S3 and encryption
    // credentials are resolved from there; otherwise sourceEncryptionKey supplies the key.
    //
    sourcePath: string;

    //
    // Destination database path (filesystem or s3: path).
    //
    destPath: string;

    //
    // Source encryption key — either a file path to a PEM file or the name of a vault secret.
    // Used when the source database is not registered in databases.json (e.g. CLI invocations).
    // Undefined for unencrypted sources or when credentials come from databases.json.
    //
    sourceEncryptionKey?: string;

    //
    // Destination encryption key — either a file path to a PEM file or the name of a vault secret.
    // Undefined for an unencrypted destination.
    //
    destEncryptionKey?: string;

    //
    // Vault secret name of S3 credentials to use when destPath starts with "s3:".
    //
    destS3Key: string | undefined;

    //
    // True for partial replication (metadata only), false for full replication (copies every original/display/thumb file).
    //
    partial: boolean;

    //
    // True to allow replication when the destination already exists with a different database id.
    //
    force: boolean;

    //
    // Optional path filter — only replicate files matching this path (file or directory).
    //
    pathFilter?: string;
}

//
// Task message sent during replication to forward progress strings to the UI.
//
export interface IReplicateProgressMessage {
    //
    // Message type discriminator.
    //
    type: "replicate-progress";

    //
    // The source database path. Used by the UI to discard messages from a closed or different replication.
    //
    databasePath: string;

    //
    // The human-readable progress string emitted by replicate().
    //
    progress: string;
}
