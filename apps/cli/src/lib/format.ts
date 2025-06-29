//
// Formats a value in bytes into a human-readable string.
//
export function formatBytes(bytes: number, options?: {
    binary?: boolean;
    decimals?: number;
    locale?: string;
}): string {
    const { binary = true, decimals = 2, locale = 'en-US' } = options || {};
    
    if (bytes === 0) return '0 Bytes';
    
    const k = binary ? 1024 : 1000;
    const sizes = binary 
        ? ['Bytes', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']
        : ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB'];
    
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    const value = bytes / Math.pow(k, i);
    
    // Intelligent decimal handling
    let formatted: string;
    if (value >= 100 || value % 1 === 0) {
        // No decimals for whole numbers or values >= 100
        formatted = Math.round(value).toLocaleString(locale);
    } else if (value >= 10) {
        // 1 decimal for values 10-99
        formatted = value.toLocaleString(locale, { 
            minimumFractionDigits: 0, 
            maximumFractionDigits: 1 
        });
    } else {
        // Up to specified decimals for small values
        formatted = value.toLocaleString(locale, { 
            minimumFractionDigits: 0, 
            maximumFractionDigits: decimals 
        });
    }
    
    return `${formatted} ${sizes[i]}`;
}

//
// Formats a duration in seconds into a human-readable string.
//
export function formatDuration(seconds: number): string {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);
    
    if (hours > 0) {
        return `${hours}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
    } else {
        return `${minutes}:${secs.toString().padStart(2, '0')}`;
    }
}

//
// Formats a bitrate in bits per second into a human-readable string.
//
export function formatBitrate(bitrate: number): string {
    if (bitrate >= 1000000) {
        return `${(bitrate / 1000000).toFixed(1)} Mbps`;
    } else if (bitrate >= 1000) {
        return `${(bitrate / 1000).toFixed(1)} Kbps`;
    } else {
        return `${bitrate} bps`;
    }
}