//
// Builds text of the given length that is not all one character and includes non-ASCII characters, for checking that a
// large message crosses the bridge whole.
//
export function makeLargePayload(length: number): string {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 \"quoted\" \\ \n é世界😀 ";
    const repeats = Math.ceil(length / alphabet.length);
    return alphabet.repeat(repeats).slice(0, length);
}
