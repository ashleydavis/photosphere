//
// The lookup table of the CRC-32 used by zlib, gzip and Zig's std.hash.Crc32.
//
const crcTable: number[] = [];
for (let tableIndex = 0; tableIndex < 256; tableIndex++) {
    let value = tableIndex;
    for (let bit = 0; bit < 8; bit++) {
        value = (value & 1) ? (0xEDB88320 ^ (value >>> 1)) : (value >>> 1);
    }
    crcTable.push(value >>> 0);
}

//
// The CRC-32 of the UTF-8 bytes of the text, as the unsigned number Zig's std.hash.Crc32 gives for the same bytes.
//
export function crc32(text: string): number {
    const bytes = new TextEncoder().encode(text);
    let crc = 0xFFFFFFFF;
    for (const byte of bytes) {
        crc = crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
}
