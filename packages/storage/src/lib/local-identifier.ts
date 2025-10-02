//
// Utility functions for working with storage.
//

//
// Gets the local identifier for a storage location.
// Used for creating unique write lock paths in the Photosphere temp directory.
//
// Examples:
// - "fs:/home/user/db" -> "fs/home/user/db"
// - "fs:D:\photos\db" -> "fs/d/photos/db"
// - "s3:bucket-name:/path/to/db" -> "s3/bucket-name/path/to/db"
//
export function getLocalIdentifier(storageLocation: string): string {
    // Handle empty string case first
    if (storageLocation === "") {
        throw new Error("Storage location cannot be empty");
    }

    let type = "fs"; // Default to file system storage

    // Remove scheme prefix if present.
    if (storageLocation.startsWith("fs:")) {
        type = "fs";
        storageLocation = storageLocation.substring(3);
    } 
    else if (storageLocation.startsWith("s3:")) {
        type = "s3";
        storageLocation = storageLocation.substring(3);
    }

    // Normalize path separators.
    storageLocation = storageLocation.replace(/\\/g, "/");

    // Replace multiple slashes with single slash.
    storageLocation = storageLocation.replace(/\/+/g, "/"); 

    // Remove leading slashes after scheme.
    while (storageLocation.startsWith("/")) {
        storageLocation = storageLocation.substring(1);
    }

    if (storageLocation === "") {
        throw new Error("Empty path after scheme");
    }
        
    // Handle Windows drive letters more explicitly
    // First replace any drive letter pattern like "C:" or "D:" with "c/" or "d/"
    if (/^[a-zA-Z]:/.test(storageLocation)) {
        const driveLetter = storageLocation.charAt(0).toLowerCase();
        const afterColon = storageLocation.substring(2);
        // Remove leading slash from afterColon to avoid double slash
        const cleanAfterColon = afterColon.startsWith("/") ? afterColon.substring(1) : afterColon;
        storageLocation = driveLetter + "/" + cleanAfterColon;
    }
        
    return type + "/" + storageLocation;
}