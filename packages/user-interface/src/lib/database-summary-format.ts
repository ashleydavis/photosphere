//
// Formats a byte count into a human-readable string (e.g. "1.5 GiB").
//
export function formatBytes(bytes: number): string {
    if (bytes === 0) {
        return "0 Bytes";
    }
    const units = ["Bytes", "KiB", "MiB", "GiB", "TiB"];
    const index = Math.floor(Math.log(bytes) / Math.log(1024));
    const value = bytes / Math.pow(1024, index);
    const formatted = value >= 100 || value % 1 === 0
        ? Math.round(value).toLocaleString()
        : value.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
    return `${formatted} ${units[index]}`;
}

//
// Determines the storage type label from a database path.
//
export function getStorageType(databasePath: string): string {
    if (databasePath.startsWith("s3:")) {
        return "S3-compatible object storage";
    }
    return "Local filesystem";
}
