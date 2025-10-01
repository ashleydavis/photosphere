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
    
    // Handle case-insensitive scheme detection
    const lowerLocation = storageLocation.toLowerCase();
    
    if (lowerLocation.startsWith("fs:")) {
        // File system storage: "fs:/path/to/db" -> "fs/path/to/db"
        const fsPath = storageLocation.substring(3); // Remove "fs:" prefix
        
        // Handle empty path after fs:
        if (fsPath === "") {
            throw new Error("Empty path after fs: scheme");
        }
        
        // Normalize path separators and handle Windows drive letters
        let normalized = fsPath.replace(/\\/g, "/");
        
        // Handle Windows drive letters (C: -> c/, C:/ -> c/) and convert to lowercase
        normalized = normalized.replace(/^([a-zA-Z]):\/?/, "$1/").toLowerCase();
        
        
        
        // Remove multiple leading slashes only (preserve internal multiple slashes)
        normalized = normalized.replace(/^\/+/, "/");
        
        return "fs" + (normalized.startsWith("/") ? normalized : "/" + normalized);
    } else if (lowerLocation.startsWith("s3:")) {
        // S3 storage: "s3:bucket-name:/path" -> "s3/bucket-name/path"
        const s3Path = storageLocation.substring(3); // Remove "s3:" prefix
        
        // Handle empty path after s3:
        if (s3Path === "") {
            throw new Error("Empty path after s3: scheme");
        }
        
        const colonIndex = s3Path.indexOf(":");
        if (colonIndex !== -1) {
            const bucket = s3Path.substring(0, colonIndex);
            const pathPart = s3Path.substring(colonIndex + 1).replace(/^\/+/, ""); // Remove leading slashes
            return `s3/${bucket}/${pathPart}`.toLowerCase();
        }
        return `s3/${s3Path}`.toLowerCase();
    } else if (storageLocation.includes("://")) {
        // Other storage types with explicit schemes (memory://, http://, etc.)
        let result = storageLocation.toLowerCase();
        result = result.replace(/\\/g, "/"); // Convert backslashes to forward slashes
        result = result.replace(/:\/\//g, "/"); // Replace :// with /
        result = result.replace(/\/+/g, "/"); // Replace multiple slashes with single slash
        result = result.replace(/^\/+/, ""); // Remove leading slashes
        result = result.replace(/:/g, "/"); // Replace remaining colons with slashes
        return result;
    } else {
        // Default to file system storage for paths without explicit scheme
        let normalized = storageLocation.replace(/\\/g, "/");
        
        // Handle Windows drive letters (C: -> c/, C:/ -> c/) and convert to lowercase
        normalized = normalized.replace(/^([a-zA-Z]):\/?/, "$1/").toLowerCase();
        
        
        
        // Remove multiple leading slashes only (preserve internal multiple slashes)
        normalized = normalized.replace(/^\/+/, "/");
        
        return "fs" + (normalized.startsWith("/") ? normalized : "/" + normalized);
    }
}