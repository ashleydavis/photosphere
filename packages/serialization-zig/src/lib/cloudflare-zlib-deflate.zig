//
// Gzip compression at level 9 that is byte-identical to Bun's `zlib.gzipSync(buffer, { level: 9 })`.
//
// This file has no TypeScript counterpart. It is a port of the deflate path of the Cloudflare zlib fork that Bun bundles
// (https://github.com/cloudflare/zlib at commit 886098f3f339617b4243b286f5ed364b9989e245, the hash that
// `process.versions.zlib` prints under Bun). The fork produces different bytes from stock zlib because it hashes
// four bytes with CRC32C (`_mm_crc32_u32` on x86_64, `__crc32cw` on arm64, identical results), requires matches of
// at least four bytes, compares matches eight bytes at a time and keeps 64 bits in the bit buffer.
//
// Only what `gzipSync` at level 9 executes is ported: deflateInit2 with windowBits 15 + 16 (gzip), memLevel 8 and the
// default strategy, then deflate() with all input available and Z_FINISH. Bun drives deflate() with 16 KiB output
// chunks, but the compressed bytes do not depend on the output chunk size (checked against the C sources), so this port
// writes to a growable buffer. Function names follow the C names (camelCased) and appear in the same order as in
// deflate.c followed by trees.c.
//

const std = @import("std");

// ---------------------------------------------------------------------------------------------------------------
// Constants (deflate.h, zutil.h)
// ---------------------------------------------------------------------------------------------------------------

//
// Number of length codes, not counting the special END_BLOCK code (LENGTH_CODES).
//
const length_codes = 29;

//
// Number of literal bytes 0..255 (LITERALS).
//
const literals = 256;

//
// Number of Literal or Length codes, including the END_BLOCK code (L_CODES).
//
const l_codes = literals + 1 + length_codes;

//
// Number of distance codes (D_CODES).
//
const d_codes = 30;

//
// Number of codes used to transfer the bit lengths (BL_CODES).
//
const bl_codes = 19;

//
// Maximum heap size (HEAP_SIZE).
//
const heap_size = 2 * l_codes + 1;

//
// All codes must not exceed MAX_BITS bits (MAX_BITS).
//
const max_bits = 15;

//
// Bit length codes must not exceed MAX_BL_BITS bits (MAX_BL_BITS).
//
const max_bl_bits = 7;

//
// End of block literal code (END_BLOCK).
//
const end_block = 256;

//
// Repeat previous bit length 3-6 times, 2 bits of repeat count (REP_3_6).
//
const rep_3_6 = 16;

//
// Repeat a zero length 3-10 times, 3 bits of repeat count (REPZ_3_10).
//
const repz_3_10 = 17;

//
// Repeat a zero length 11-138 times, 7 bits of repeat count (REPZ_11_138).
//
const repz_11_138 = 18;

//
// Block type of a stored block (STORED_BLOCK).
//
const stored_block = 0;

//
// Block type of a block that uses the static trees (STATIC_TREES).
//
const static_trees = 1;

//
// Block type of a block that uses dynamic trees (DYN_TREES).
//
const dyn_trees = 2;

//
// The minimum match length that the length codes encode (MIN_MATCH).
//
const min_match = 3;

//
// The maximum match length (MAX_MATCH).
//
const max_match = 258;

//
// The minimum match length that the Cloudflare fork searches for (ACTUAL_MIN_MATCH).
//
const actual_min_match = 4;

//
// Minimum amount of lookahead, except at the end of the input file (MIN_LOOKAHEAD).
//
const min_lookahead = max_match + min_match + 1;

//
// Tail of hash chains (NIL).
//
const nil = 0;

//
// Number of bytes after the end of data in the window to initialize (WIN_INIT).
//
const win_init = max_match;

//
// log2 of the LZ77 window size (windowBits 15 + 16 minus the 16 that selects gzip).
//
const w_bits = 15;

//
// LZ77 window size (w_size).
//
const w_size: u32 = 1 << w_bits;

//
// w_size - 1 (w_mask).
//
const w_mask: u32 = w_size - 1;

//
// Actual size of the window: 2 * w_size (window_size).
//
const window_size: u32 = 2 * w_size;

//
// Matches are limited to this distance (MAX_DIST).
//
const max_dist: u32 = w_size - min_lookahead;

//
// Bytes of zero padding after the window, so that the eight-byte loads of longestMatch never leave the allocation
// (the C code reads up to three bytes past its window, which never changes the result).
//
const window_padding = 8;

//
// memLevel used by Bun (DEF_MEM_LEVEL).
//
const mem_level = 8;

//
// log2 of the number of hash chain heads (hash_bits = memLevel + 7).
//
const hash_bits = mem_level + 7;

//
// Number of hash chain heads (hash_size).
//
const hash_size: u32 = 1 << hash_bits;

//
// hash_size - 1 (hash_mask).
//
const hash_mask: u32 = hash_size - 1;

//
// Size of the symbol buffer in symbols (lit_bufsize = 1 << (memLevel + 6)).
//
const lit_bufsize: u32 = 1 << (mem_level + 6);

//
// The symbol table is full when sym_next reaches this (sym_end).
//
const sym_end: u32 = (lit_bufsize - 1) * 3;

//
// Level 9 row of configuration_table: reduce lazy search above this match length (good_length).
//
const good_match: u32 = 32;

//
// Level 9 row of configuration_table: do not perform lazy search above this match length (max_lazy).
//
const max_lazy_match: u32 = 258;

//
// Level 9 row of configuration_table: quit search above this match length (nice_length).
//
const nice_match: u32 = 258;

//
// Level 9 row of configuration_table: maximum hash chain length (max_chain).
//
const max_chain_length: u32 = 4096;

//
// The gzip header XFL byte for level 9.
//
const gzip_extra_flags_level_9 = 2;

//
// The gzip header OS byte (OS_CODE, Unix).
//
const os_code = 3;

// ---------------------------------------------------------------------------------------------------------------
// Static tables (trees.c)
// ---------------------------------------------------------------------------------------------------------------

//
// Extra bits for each length code (extra_lbits).
//
const extra_lbits = [length_codes]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

//
// Extra bits for each distance code (extra_dbits).
//
const extra_dbits = [d_codes]u32{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

//
// Extra bits for each bit length code (extra_blbits).
//
const extra_blbits = [bl_codes]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7 };

//
// The lengths of the bit length codes are sent in order of decreasing probability (bl_order).
//
const bl_order = [bl_codes]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

//
// Size of the _dist_code table (DIST_CODE_LEN).
//
const dist_code_len = 512;

//
// A tree element (ct_data). In C both fields are unions: the first holds the frequency count while a tree is built and
// the bit string afterwards, the second holds the father node while a tree is built and the bit length afterwards.
//
const CtData = struct {
    // Frequency count (Freq) or bit string (Code).
    freqOrCode: u16,

    // Father node in the Huffman tree (Dad) or length of the bit string (Len).
    dadOrLen: u16,
};

//
// The constant tables that tr_static_init computes.
//
const StaticTables = struct {
    // The static literal tree, including the codes 286 and 287 that are needed to build a canonical tree (static_ltree).
    staticLtree: [l_codes + 2]CtData,

    // The static distance tree (static_dtree).
    staticDtree: [d_codes]CtData,

    // Distance codes: the first 256 values are for distances 3 .. 258, the last 256 for the top 8 bits of 15 bit distances (_dist_code).
    distCode: [dist_code_len]u8,

    // Length code for each normalized match length, 0 == MIN_MATCH (_length_code).
    lengthCode: [max_match - min_match + 1]u8,

    // First normalized length for each code, 0 = MIN_MATCH (base_length).
    baseLength: [length_codes]u32,

    // First normalized distance for each code, 0 = distance of 1 (base_dist).
    baseDist: [d_codes]u32,
};

//
// Initializes the various 'constant' tables (tr_static_init). Evaluated at compile time.
//
fn trStaticInit() StaticTables {
    @setEvalBranchQuota(100000);
    var tables: StaticTables = undefined;
    var blCount = [_]u16{0} ** (max_bits + 1);

    // Initialize the mapping length (0..255) -> length code (0..28)
    var length: u32 = 0;
    var code: u32 = 0;
    while (code < length_codes - 1) : (code += 1) {
        tables.baseLength[code] = length;
        var count: u32 = 0;
        while (count < (@as(u32, 1) << @intCast(extra_lbits[code]))) : (count += 1) {
            tables.lengthCode[length] = @intCast(code);
            length += 1;
        }
    }
    // Note that the length 255 (match length 258) can be represented in two different ways: code 284 + 5 bits or
    // code 285, so we overwrite length_code[255] to use the best encoding:
    tables.lengthCode[length - 1] = @intCast(code);
    tables.baseLength[length_codes - 1] = 0;

    // Initialize the mapping dist (0..32K) -> dist code (0..29)
    var dist: u32 = 0;
    code = 0;
    while (code < 16) : (code += 1) {
        tables.baseDist[code] = dist;
        var count: u32 = 0;
        while (count < (@as(u32, 1) << @intCast(extra_dbits[code]))) : (count += 1) {
            tables.distCode[dist] = @intCast(code);
            dist += 1;
        }
    }
    // from now on, all distances are divided by 128
    dist >>= 7;
    while (code < d_codes) : (code += 1) {
        tables.baseDist[code] = dist << 7;
        var count: u32 = 0;
        while (count < (@as(u32, 1) << @intCast(extra_dbits[code] - 7))) : (count += 1) {
            tables.distCode[256 + dist] = @intCast(code);
            dist += 1;
        }
    }
    // _dist_code[256] and _dist_code[257] are never used (zero in trees.h).
    tables.distCode[256] = 0;
    tables.distCode[257] = 0;

    // Construct the codes of the static literal tree
    var index: usize = 0;
    while (index <= 143) : (index += 1) {
        tables.staticLtree[index].dadOrLen = 8;
        blCount[8] += 1;
    }
    while (index <= 255) : (index += 1) {
        tables.staticLtree[index].dadOrLen = 9;
        blCount[9] += 1;
    }
    while (index <= 279) : (index += 1) {
        tables.staticLtree[index].dadOrLen = 7;
        blCount[7] += 1;
    }
    while (index <= 287) : (index += 1) {
        tables.staticLtree[index].dadOrLen = 8;
        blCount[8] += 1;
    }
    // Codes 286 and 287 do not exist, but we must include them in the tree construction to get a canonical Huffman
    // tree (longest code all ones)
    genCodes(&tables.staticLtree, l_codes + 1, &blCount);

    // The static distance tree is trivial:
    index = 0;
    while (index < d_codes) : (index += 1) {
        tables.staticDtree[index].dadOrLen = 5;
        tables.staticDtree[index].freqOrCode = @intCast(biReverse(@intCast(index), 5));
    }
    return tables;
}

//
// The constant tables, computed at compile time.
//
const static_tables: StaticTables = trStaticInit();

//
// Describes the static part of a tree (static_tree_desc).
//
const StaticTreeDesc = struct {
    // Static tree or null (static_tree).
    staticTree: ?[]const CtData,

    // Extra bits for each code (extra_bits).
    extraBits: []const u32,

    // Base index for extra_bits (extra_base).
    extraBase: usize,

    // Max number of elements in the tree (elems).
    elems: usize,

    // Max bit length for the codes (max_length).
    maxLength: u32,
};

//
// Static description of the literal tree (static_l_desc).
//
const static_l_desc = StaticTreeDesc{
    .staticTree = &static_tables.staticLtree,
    .extraBits = &extra_lbits,
    .extraBase = literals + 1,
    .elems = l_codes,
    .maxLength = max_bits,
};

//
// Static description of the distance tree (static_d_desc).
//
const static_d_desc = StaticTreeDesc{
    .staticTree = &static_tables.staticDtree,
    .extraBits = &extra_dbits,
    .extraBase = 0,
    .elems = d_codes,
    .maxLength = max_bits,
};

//
// Static description of the bit length tree (static_bl_desc).
//
const static_bl_desc = StaticTreeDesc{
    .staticTree = null,
    .extraBits = &extra_blbits,
    .extraBase = 0,
    .elems = bl_codes,
    .maxLength = max_bl_bits,
};

//
// A dynamic tree and its static description (tree_desc).
//
const TreeDesc = struct {
    // The dynamic tree (dyn_tree).
    dynTree: []CtData,

    // Largest code with non zero frequency (max_code).
    maxCode: i32,

    // The corresponding static tree (stat_desc).
    statDesc: *const StaticTreeDesc,
};

// ---------------------------------------------------------------------------------------------------------------
// Compression state (deflate_state)
// ---------------------------------------------------------------------------------------------------------------

//
// The internal compression state of one gzip stream (deflate_state plus the z_stream fields it uses).
//
const DeflateState = struct {
    // Allocates the output.
    allocator: std.mem.Allocator,

    // The whole input (z_stream next_in at the start).
    input: []const u8,

    // Index of the next input byte to read (z_stream next_in).
    nextIn: usize,

    // Total number of input bytes read so far (z_stream total_in).
    totalIn: u64,

    // The compressed output, including bytes C keeps in pending_buf until flush_pending copies them out.
    output: std.ArrayList(u8),

    // Sliding window of window_size bytes plus zero padding (window).
    window: []u8,

    // Link to older string with same hash index (prev).
    prev: []u16,

    // Heads of the hash chains or NIL (head).
    head: []u16,

    // Hash index of string to be inserted (ins_h).
    insHash: u32,

    // Window position at the beginning of the current output block; negative when the window is moved backwards (block_start).
    blockStart: i64,

    // Length of best match (match_length).
    matchLength: u32,

    // Previous match (prev_match).
    prevMatch: u32,

    // Set if previous match exists (match_available).
    matchAvailable: bool,

    // Start of string to insert (strstart).
    strStart: u32,

    // Start of matching string (match_start).
    matchStart: u32,

    // Number of valid bytes ahead in window (lookahead).
    lookahead: u32,

    // Length of the best match at previous step (prev_length).
    prevLength: u32,

    // Bytes at end of window left to insert (insert).
    insert: u32,

    // High water mark offset in window for initialized bytes (high_water).
    highWater: u64,

    // Literal and length tree (dyn_ltree).
    dynLtree: [heap_size]CtData,

    // Distance tree (dyn_dtree).
    dynDtree: [2 * d_codes + 1]CtData,

    // Huffman tree for bit lengths (bl_tree).
    blTree: [2 * bl_codes + 1]CtData,

    // Descriptor for the literal tree (l_desc).
    lDesc: TreeDesc,

    // Descriptor for the distance tree (d_desc).
    dDesc: TreeDesc,

    // Descriptor for the bit length tree (bl_desc).
    blDesc: TreeDesc,

    // Number of codes at each bit length for an optimal tree (bl_count).
    blCount: [max_bits + 1]u16,

    // Heap used to build the Huffman trees (heap).
    heap: [2 * l_codes + 1]i32,

    // Number of elements in the heap (heap_len).
    heapLen: i32,

    // Element of largest frequency (heap_max).
    heapMax: i32,

    // Depth of each subtree used as tie breaker for trees of equal frequency (depth).
    depth: [2 * l_codes + 1]u8,

    // Buffer for distances and literals/lengths, three bytes per symbol (sym_buf).
    symBuf: []u8,

    // Running index in sym_buf (sym_next).
    symNext: u32,

    // Bit length of current block with optimal trees (opt_len).
    optLen: u64,

    // Bit length of current block with static trees (static_len).
    staticLen: u64,

    // Output bit buffer; bits are inserted starting at the bottom (bi_buf).
    biBuf: u64,

    // Number of valid bits in bi_buf (bi_valid).
    biValid: u32,
};

// ---------------------------------------------------------------------------------------------------------------
// deflate.c
// ---------------------------------------------------------------------------------------------------------------

//
// CRC32C (Castagnoli, reflected polynomial 0x82F63B78) lookup table used by hashFunc.
//
const crc32c_table: [256]u32 = computeCrc32cTable();

//
// Computes the CRC32C lookup table at compile time.
//
fn computeCrc32cTable() [256]u32 {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    var byteValue: u32 = 0;
    while (byteValue < 256) : (byteValue += 1) {
        var crc = byteValue;
        var bit: u32 = 0;
        while (bit < 8) : (bit += 1) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0x82F63B78;
            }
            else {
                crc >>= 1;
            }
        }
        table[byteValue] = crc;
    }
    return table;
}

//
// Hashes the four bytes at window[str] (hash_func): `_mm_crc32_u32(0, *(uint32_t*)str) & hash_mask`, which is CRC32C
// with an initial value of 0 and no final xor over the four bytes in little endian order.
//
fn hashFunc(state: *const DeflateState, str: usize) u32 {
    var crc: u32 = 0;
    for (state.window[str .. str + 4]) |byte| {
        crc = crc32c_table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    return crc & hash_mask;
}

//
// Inserts string str in the dictionary and returns the previous head of the hash chain (insert_string).
//
fn insertString(state: *DeflateState, str: u16) u16 {
    state.insHash = hashFunc(state, str);
    const matchHead = state.head[state.insHash];
    state.prev[str & w_mask] = matchHead;
    state.head[state.insHash] = str;
    return matchHead;
}

//
// Inserts count strings starting at startpos in the dictionary (bulk_insert_str).
//
fn bulkInsertStr(state: *DeflateState, startpos: u16, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const position: u32 = @as(u32, startpos) + index;
        state.insHash = hashFunc(state, position);
        state.prev[position & w_mask] = state.head[state.insHash];
        state.head[state.insHash] = @truncate(position);
    }
}

//
// Creates the compression state (deflateInit2_ with level 9, Z_DEFLATED, windowBits 31, memLevel 8, Z_DEFAULT_STRATEGY,
// followed by deflateReset, deflateResetKeep, _tr_init and lm_init).
//
fn deflateInit(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!*DeflateState {
    const state = try allocator.create(DeflateState);
    state.allocator = allocator;
    state.input = input;
    state.nextIn = 0;
    state.totalIn = 0;
    state.output = .empty;

    // The window is zeroed so the bytes past the padding are defined; fillWindow zeroes the bytes C would read (high_water).
    state.window = try allocator.alloc(u8, window_size + window_padding);
    @memset(state.window, 0);
    state.prev = try allocator.alloc(u16, w_size);
    @memset(state.prev, 0);
    state.head = try allocator.alloc(u16, hash_size);
    state.highWater = 0;
    state.symBuf = try allocator.alloc(u8, lit_bufsize * 3);

    // deflateResetKeep and _tr_init
    state.lDesc = .{ .dynTree = &state.dynLtree, .maxCode = 0, .statDesc = &static_l_desc };
    state.dDesc = .{ .dynTree = &state.dynDtree, .maxCode = 0, .statDesc = &static_d_desc };
    state.blDesc = .{ .dynTree = &state.blTree, .maxCode = 0, .statDesc = &static_bl_desc };
    @memset(&state.dynLtree, .{ .freqOrCode = 0, .dadOrLen = 0 });
    @memset(&state.dynDtree, .{ .freqOrCode = 0, .dadOrLen = 0 });
    @memset(&state.blTree, .{ .freqOrCode = 0, .dadOrLen = 0 });
    @memset(&state.blCount, 0);
    @memset(&state.heap, 0);
    @memset(&state.depth, 0);
    state.heapLen = 0;
    state.heapMax = 0;
    state.biBuf = 0;
    state.biValid = 0;
    initBlock(state);

    // lm_init
    lmInit(state);
    return state;
}

//
// Compresses the whole input as one gzip member (deflate called with Z_FINISH until Z_STREAM_END).
//
fn deflate(state: *DeflateState) std.mem.Allocator.Error!void {
    // Write the header
    try state.output.appendSlice(state.allocator, &.{ 31, 139, 8, 0, 0, 0, 0, 0, gzip_extra_flags_level_9, os_code });

    // Start a new block or continue the current one.
    try deflateSlow(state);

    // Write the trailer
    const crc = std.hash.Crc32.hash(state.input);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], crc, .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(state.totalIn), .little);
    try state.output.appendSlice(state.allocator, &trailer);
}

//
// Reads a new buffer from the input into buf and updates the total number of bytes read (read_buf). The CRC-32 of the
// input is computed over the whole input when the trailer is written, which gives the same value.
//
fn readBuf(state: *DeflateState, bufferStart: usize, size: u32) u32 {
    var length: usize = state.input.len - state.nextIn;
    if (length > size) {
        length = size;
    }
    if (length == 0) {
        return 0;
    }
    @memcpy(state.window[bufferStart .. bufferStart + length], state.input[state.nextIn .. state.nextIn + length]);
    state.nextIn += length;
    state.totalIn += length;
    return @intCast(length);
}

//
// Initializes the "longest match" routines for a new zlib stream (lm_init).
//
fn lmInit(state: *DeflateState) void {
    // CLEAR_HASH
    @memset(state.head, 0);

    state.strStart = 0;
    state.blockStart = 0;
    state.lookahead = 0;
    state.insert = 0;
    state.matchLength = actual_min_match - 1;
    state.prevLength = actual_min_match - 1;
    state.matchAvailable = false;
    state.insHash = 0;
    state.matchStart = 0;
    state.prevMatch = 0;
}

//
// Reads four bytes of the window in little endian order (`*(uint32_t*)`).
//
fn readWindow32(state: *const DeflateState, position: usize) u32 {
    return std.mem.readInt(u32, state.window[position..][0..4], .little);
}

//
// Reads eight bytes of the window in little endian order (`*(uint64_t*)`).
//
fn readWindow64(state: *const DeflateState, position: usize) u64 {
    return std.mem.readInt(u64, state.window[position..][0..8], .little);
}

//
// Finds the longest match starting at curMatch and sets matchStart (longest_match, the Cloudflare version that
// compares four bytes before the chain walk and eight bytes at a time after it).
//
fn longestMatch(state: *DeflateState, curMatchStart: u32) u32 {
    var curMatch = curMatchStart;
    // max hash chain length
    var chainLength: u32 = max_chain_length;
    // current string
    const scanStart: usize = state.strStart;
    // best match length so far
    var bestLen: i32 = @intCast(state.prevLength);
    // stop if match long enough
    var niceMatch: i32 = @intCast(nice_match);
    // Stop when cur_match becomes <= limit. To simplify the code, we prevent matches with the string of window index 0.
    const limit: u32 = if (state.strStart > max_dist) state.strStart - max_dist else nil;

    const strend: usize = state.strStart + max_match;
    // We optimize for a minimal match of four bytes
    const scanStartValue = readWindow32(state, scanStart);
    var scanEndValue = readWindow32(state, scanStart + @as(usize, @intCast(bestLen)) - 3);

    // Do not waste too much time if we already have a good match:
    if (state.prevLength >= good_match) {
        chainLength >>= 2;
    }
    // Do not look for matches beyond the end of the input. This is necessary to make deflate deterministic.
    if (@as(u32, @intCast(niceMatch)) > state.lookahead) {
        niceMatch = @intCast(state.lookahead);
    }

    while (true) {
        // Skip to next match if the match length cannot increase or if the match length is less than 2.
        var cont = true;
        var matchPosition: usize = 0;
        while (true) {
            matchPosition = curMatch;
            if (readWindow32(state, matchPosition + @as(usize, @intCast(bestLen)) - 3) != scanEndValue or readWindow32(state, matchPosition) != scanStartValue) {
                curMatch = state.prev[curMatch & w_mask];
                if (curMatch > limit) {
                    chainLength -= 1;
                    if (chainLength != 0) {
                        continue;
                    }
                }
                cont = false;
            }
            break;
        }

        if (!cont) {
            break;
        }

        var scan: usize = scanStart + 4;
        matchPosition += 4;
        while (true) {
            const scanValue = readWindow64(state, scan);
            const matchValue = readWindow64(state, matchPosition);
            const difference = scanValue ^ matchValue;
            if (difference != 0) {
                const matchByte: usize = @ctz(difference) / 8;
                scan += matchByte;
                matchPosition += matchByte;
                break;
            }
            else {
                scan += 8;
                matchPosition += 8;
            }
            if (scan >= strend) {
                break;
            }
        }

        if (scan > strend) {
            scan = strend;
        }

        const len: i32 = max_match - @as(i32, @intCast(strend - scan));

        if (len > bestLen) {
            state.matchStart = curMatch;
            bestLen = len;
            if (len >= niceMatch) {
                break;
            }
            scanEndValue = readWindow32(state, scanStart + @as(usize, @intCast(bestLen)) - 3);
        }

        curMatch = state.prev[curMatch & w_mask];
        if (curMatch <= limit) {
            break;
        }
        chainLength -= 1;
        if (chainLength == 0) {
            break;
        }
    }

    if (@as(u32, @intCast(bestLen)) <= state.lookahead) {
        return @intCast(bestLen);
    }
    return state.lookahead;
}

//
// Subtracts wsize from every entry of a hash table, saturating at zero (the SSE2 / NEON loops of fill_window).
//
fn slideHashTable(table: []u16) void {
    for (table) |*entry| {
        entry.* = entry.* -| @as(u16, @intCast(w_size));
    }
}

//
// Fills the window when the lookahead becomes insufficient. Updates strstart and lookahead (fill_window).
//
fn fillWindow(state: *DeflateState) void {
    while (true) {
        // Amount of free space at the end of the window.
        var more: u32 = window_size - state.lookahead - state.strStart;

        // If the window is almost full and there is insufficient lookahead, move the upper half to the lower one to
        // make room in the upper half.
        if (state.strStart >= w_size + max_dist) {
            @memcpy(state.window[0..w_size], state.window[w_size .. 2 * w_size]);
            state.matchStart -%= w_size;
            state.strStart -= w_size;
            state.blockStart -= w_size;
            slideHashTable(state.head);
            slideHashTable(state.prev);
            more += w_size;
        }
        if (state.nextIn == state.input.len) {
            break;
        }

        const bytesRead = readBuf(state, state.strStart + state.lookahead, more);
        state.lookahead += bytesRead;

        // Initialize the hash value now that we have some input:
        if (state.lookahead + state.insert >= actual_min_match) {
            var str: u32 = state.strStart - state.insert;
            var insHash: u32 = state.window[str];
            while (state.insert != 0) {
                insHash = hashFunc(state, str);
                state.prev[str & w_mask] = state.head[insHash];
                state.head[insHash] = @truncate(str);
                str += 1;
                state.insert -= 1;
                if (state.lookahead + state.insert < actual_min_match) {
                    break;
                }
            }
            state.insHash = insHash;
        }
        // If the whole input has less than ACTUAL_MIN_MATCH bytes, ins_h is garbage, but this is not important since
        // only literal bytes will be emitted.

        if (!(state.lookahead < min_lookahead and state.nextIn != state.input.len)) {
            break;
        }
    }

    // If the WIN_INIT bytes after the end of the current data have never been written, then zero those bytes in order
    // to avoid memory check reports of the use of uninitialized bytes by the longest match routines. Update the high
    // water mark for the next time through here.
    if (state.highWater < window_size) {
        const curr: u64 = @as(u64, state.strStart) + state.lookahead;
        var init: u64 = 0;

        if (state.highWater < curr) {
            // Previous high water mark below current data -- zero WIN_INIT bytes or up to end of window, whichever is less.
            init = window_size - curr;
            if (init > win_init) {
                init = win_init;
            }
            @memset(state.window[@intCast(curr)..@intCast(curr + init)], 0);
            state.highWater = curr + init;
        }
        else if (state.highWater < curr + win_init) {
            // High water mark at or above current data, but below current data plus WIN_INIT -- zero out to current
            // data plus WIN_INIT, or up to end of window, whichever is less.
            init = curr + win_init - state.highWater;
            if (init > window_size - state.highWater) {
                init = window_size - state.highWater;
            }
            @memset(state.window[@intCast(state.highWater)..@intCast(state.highWater + init)], 0);
            state.highWater += init;
        }
    }
}

//
// Flushes the current block, with given end-of-file flag (FLUSH_BLOCK_ONLY / FLUSH_BLOCK; the output never fills up).
//
fn flushBlock(state: *DeflateState, last: bool) std.mem.Allocator.Error!void {
    const buffer: ?usize = if (state.blockStart >= 0) @intCast(state.blockStart) else null;
    const storedLen: u64 = @intCast(@as(i64, state.strStart) - state.blockStart);
    try trFlushBlock(state, buffer, storedLen, last);
    state.blockStart = state.strStart;
    // flush_pending
    try trFlushBits(state);
}

//
// Records a literal byte in the symbol buffer and returns true if the block must be flushed (_tr_tally_lit).
//
fn trTallyLit(state: *DeflateState, literal: u8) bool {
    state.symBuf[state.symNext] = 0;
    state.symBuf[state.symNext + 1] = 0;
    state.symBuf[state.symNext + 2] = literal;
    state.symNext += 3;
    state.dynLtree[literal].freqOrCode += 1;
    return state.symNext == sym_end;
}

//
// Records a match in the symbol buffer and returns true if the block must be flushed (_tr_tally_dist).
//
fn trTallyDist(state: *DeflateState, distance: u32, length: u32) bool {
    const len: u8 = @truncate(length);
    var dist: u16 = @truncate(distance);
    state.symBuf[state.symNext] = @truncate(dist);
    state.symBuf[state.symNext + 1] = @truncate(dist >> 8);
    state.symBuf[state.symNext + 2] = len;
    state.symNext += 3;
    dist -%= 1;
    state.dynLtree[@as(usize, static_tables.lengthCode[len]) + literals + 1].freqOrCode += 1;
    state.dynDtree[dCode(dist)].freqOrCode += 1;
    return state.symNext == sym_end;
}

//
// Maps a distance - 1 to a distance code (d_code).
//
fn dCode(dist: u32) usize {
    if (dist < 256) {
        return static_tables.distCode[dist];
    }
    return static_tables.distCode[256 + (dist >> 7)];
}

//
// Compresses the whole input with lazy evaluation of matches: a match is finally adopted only if there is no better
// match at the next window position (deflate_slow, called with Z_FINISH).
//
fn deflateSlow(state: *DeflateState) std.mem.Allocator.Error!void {
    // Process the input block.
    while (true) {
        // Make sure that we always have enough lookahead, except at the end of the input file. We need MAX_MATCH
        // bytes for the next match, plus ACTUAL_MIN_MATCH bytes to insert the string following the next match.
        if (state.lookahead < min_lookahead) {
            fillWindow(state);
            if (state.lookahead == 0) {
                // flush the current block
                break;
            }
        }

        // Insert the string window[strstart .. strstart+3] in the dictionary, and set hash_head to the head of the
        // hash chain:
        var hashHead: u32 = nil;
        if (state.lookahead >= actual_min_match) {
            hashHead = insertString(state, @intCast(state.strStart));
        }

        // Find the longest match, discarding those <= prev_length.
        state.prevLength = state.matchLength;
        state.prevMatch = state.matchStart;
        state.matchLength = actual_min_match - 1;

        if (hashHead != nil and state.prevLength < max_lazy_match and state.strStart -% hashHead <= max_dist) {
            // To simplify the code, we prevent matches with the string of window index 0 (in particular we have to
            // avoid a match of the string with itself at the start of the input file).
            state.matchLength = longestMatch(state, hashHead);
            // longest_match() sets match_start
        }
        // If there was a match at the previous step and the current match is not better, output the previous match:
        if (state.prevLength >= actual_min_match and state.matchLength <= state.prevLength) {
            // Do not insert strings in hash table beyond this.
            const maxInsert: u32 = state.strStart +% state.lookahead -% actual_min_match;

            const bflush = trTallyDist(state, state.strStart - 1 - state.prevMatch, state.prevLength - min_match);

            // Insert in hash table all strings up to the end of the match. strstart - 1 and strstart are already
            // inserted. If there is not enough lookahead, the last two strings are not inserted in the hash table.
            state.lookahead -= state.prevLength - 1;

            const movFwd: u32 = state.prevLength - 2;
            var insertCnt: u32 = movFwd;
            if (insertCnt > maxInsert -% state.strStart) {
                insertCnt = maxInsert -% state.strStart;
            }

            bulkInsertStr(state, @truncate(state.strStart + 1), insertCnt);
            state.prevLength = 0;
            state.matchAvailable = false;
            state.matchLength = actual_min_match - 1;
            state.strStart += movFwd + 1;

            if (bflush) {
                try flushBlock(state, false);
            }
        }
        else if (state.matchAvailable) {
            // If there was no match at the previous position, output a single literal. If there was a match but the
            // current match is longer, truncate the previous match to a single literal.
            const bflush = trTallyLit(state, state.window[state.strStart - 1]);
            if (bflush) {
                try flushBlock(state, false);
            }
            state.strStart += 1;
            state.lookahead -= 1;
        }
        else {
            // There is no previous match to compare with, wait for the next step to decide.
            state.matchAvailable = true;
            state.strStart += 1;
            state.lookahead -= 1;
        }
    }
    if (state.matchAvailable) {
        _ = trTallyLit(state, state.window[state.strStart - 1]);
        state.matchAvailable = false;
    }
    state.insert = if (state.strStart < actual_min_match - 1) state.strStart else actual_min_match - 1;
    try flushBlock(state, true);
}

// ---------------------------------------------------------------------------------------------------------------
// trees.c
// ---------------------------------------------------------------------------------------------------------------

//
// Appends a byte to the output (put_byte).
//
fn putByte(state: *DeflateState, value: u8) std.mem.Allocator.Error!void {
    try state.output.append(state.allocator, value);
}

//
// Appends a 16-bit value to the output, LSB first (put_short).
//
fn putShort(state: *DeflateState, value: u16) std.mem.Allocator.Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try state.output.appendSlice(state.allocator, &bytes);
}

//
// Sends a value on a given number of bits (send_bits, with the 64-bit bit buffer of the Cloudflare fork).
//
fn sendBits(state: *DeflateState, value: u64, length: u32) std.mem.Allocator.Error!void {
    state.biBuf ^= value << @intCast(state.biValid);
    state.biValid += length;
    if (state.biValid >= 64) {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, state.biBuf, .little);
        try state.output.appendSlice(state.allocator, &bytes);
        state.biValid -= 64;
        state.biBuf = std.math.shr(u64, value, length - state.biValid);
    }
}

//
// Sends the code of symbol code of the given tree (send_code).
//
fn sendCode(state: *DeflateState, code: usize, tree: []const CtData) std.mem.Allocator.Error!void {
    try sendBits(state, tree[code].freqOrCode, tree[code].dadOrLen);
}

//
// Initializes a new block (init_block).
//
fn initBlock(state: *DeflateState) void {
    // Initialize the trees.
    var index: usize = 0;
    while (index < l_codes) : (index += 1) {
        state.dynLtree[index].freqOrCode = 0;
    }
    index = 0;
    while (index < d_codes) : (index += 1) {
        state.dynDtree[index].freqOrCode = 0;
    }
    index = 0;
    while (index < bl_codes) : (index += 1) {
        state.blTree[index].freqOrCode = 0;
    }

    state.dynLtree[end_block].freqOrCode = 1;
    state.optLen = 0;
    state.staticLen = 0;
    state.symNext = 0;
}

//
// Index within the heap array of least frequent node in the Huffman tree (SMALLEST).
//
const smallest = 1;

//
// Removes the smallest element from the heap and recreates the heap with one less element (pqremove).
//
fn pqremove(state: *DeflateState, tree: []const CtData) i32 {
    const top = state.heap[smallest];
    state.heap[smallest] = state.heap[@intCast(state.heapLen)];
    state.heapLen -= 1;
    pqdownheap(state, tree, smallest);
    return top;
}

//
// Compares two subtrees, using the tree depth as tie breaker when the subtrees have equal frequency (smaller).
//
fn smaller(tree: []const CtData, first: i32, second: i32, depth: []const u8) bool {
    const firstIndex: usize = @intCast(first);
    const secondIndex: usize = @intCast(second);
    return tree[firstIndex].freqOrCode < tree[secondIndex].freqOrCode or
        (tree[firstIndex].freqOrCode == tree[secondIndex].freqOrCode and depth[firstIndex] <= depth[secondIndex]);
}

//
// Restores the heap property by moving down the tree starting at node k (pqdownheap).
//
fn pqdownheap(state: *DeflateState, tree: []const CtData, startNode: i32) void {
    var node = startNode;
    const value = state.heap[@intCast(node)];
    // left son of k
    var son = node << 1;
    while (son <= state.heapLen) {
        // Set j to the smallest of the two sons:
        if (son < state.heapLen and smaller(tree, state.heap[@intCast(son + 1)], state.heap[@intCast(son)], &state.depth)) {
            son += 1;
        }
        // Exit if v is smaller than both sons
        if (smaller(tree, value, state.heap[@intCast(son)], &state.depth)) {
            break;
        }

        // Exchange v with the smallest son
        state.heap[@intCast(node)] = state.heap[@intCast(son)];
        node = son;

        // And continue down the tree, setting j to the left son of k
        son <<= 1;
    }
    state.heap[@intCast(node)] = value;
}

//
// Computes the optimal bit lengths for a tree and updates the total bit length for the current block (gen_bitlen).
//
fn genBitlen(state: *DeflateState, desc: *TreeDesc) void {
    const tree = desc.dynTree;
    const maxCode = desc.maxCode;
    const stree = desc.statDesc.staticTree;
    const extra = desc.statDesc.extraBits;
    const base = desc.statDesc.extraBase;
    const maxLength = desc.statDesc.maxLength;
    // number of elements with bit length too large
    var overflow: i32 = 0;

    @memset(&state.blCount, 0);

    // In a first pass, compute the optimal bit lengths (which may overflow in the case of the bit length tree).
    // root of the heap
    tree[@intCast(state.heap[@intCast(state.heapMax)])].dadOrLen = 0;

    var heapIndex: usize = @intCast(state.heapMax + 1);
    while (heapIndex < heap_size) : (heapIndex += 1) {
        const node: usize = @intCast(state.heap[heapIndex]);
        var bits: u32 = @as(u32, tree[tree[node].dadOrLen].dadOrLen) + 1;
        if (bits > maxLength) {
            bits = maxLength;
            overflow += 1;
        }
        // We overwrite tree[n].Dad which is no longer needed
        tree[node].dadOrLen = @intCast(bits);

        // not a leaf node
        if (@as(i32, @intCast(node)) > maxCode) {
            continue;
        }

        state.blCount[bits] += 1;
        var xbits: u32 = 0;
        if (node >= base) {
            xbits = extra[node - base];
        }
        const frequency: u64 = tree[node].freqOrCode;
        state.optLen +%= frequency * (bits + xbits);
        if (stree) |staticTree| {
            state.staticLen +%= frequency * (staticTree[node].dadOrLen + xbits);
        }
    }
    if (overflow == 0) {
        return;
    }

    // Find the first bit length which could increase:
    while (true) {
        var bits: usize = maxLength - 1;
        while (state.blCount[bits] == 0) {
            bits -= 1;
        }
        // move one leaf down the tree
        state.blCount[bits] -= 1;
        // move one overflow item as its brother
        state.blCount[bits + 1] += 2;
        state.blCount[maxLength] -= 1;
        // The brother of the overflow item also moves one step up, but this does not affect bl_count[max_length]
        overflow -= 2;
        if (overflow <= 0) {
            break;
        }
    }

    // Now recompute all bit lengths, scanning in increasing frequency. h is still equal to HEAP_SIZE.
    var bits: u32 = maxLength;
    while (bits != 0) : (bits -= 1) {
        var count: u32 = state.blCount[bits];
        while (count != 0) {
            heapIndex -= 1;
            const node = state.heap[heapIndex];
            if (node > maxCode) {
                continue;
            }
            const nodeIndex: usize = @intCast(node);
            if (tree[nodeIndex].dadOrLen != bits) {
                const difference: i64 = (@as(i64, bits) - @as(i64, tree[nodeIndex].dadOrLen)) * @as(i64, tree[nodeIndex].freqOrCode);
                state.optLen +%= @bitCast(difference);
                tree[nodeIndex].dadOrLen = @intCast(bits);
            }
            count -= 1;
        }
    }
}

//
// Generates the codes for a given tree and bit counts (gen_codes).
//
fn genCodes(tree: []CtData, maxCode: i32, blCount: []const u16) void {
    // next code value for each bit length
    var nextCode: [max_bits + 1]u16 = undefined;
    nextCode[0] = 0;
    // running code value
    var code: u32 = 0;

    // The distribution counts are first used to generate the code values without bit reversal.
    var bits: usize = 1;
    while (bits <= max_bits) : (bits += 1) {
        code = ((code + blCount[bits - 1]) << 1) & 0xffff;
        nextCode[bits] = @intCast(code);
    }

    var index: usize = 0;
    while (@as(i32, @intCast(index)) <= maxCode) : (index += 1) {
        const len = tree[index].dadOrLen;
        if (len == 0) {
            continue;
        }
        // Now reverse the bits
        tree[index].freqOrCode = @intCast(biReverse(nextCode[len], len));
        nextCode[len] +%= 1;
    }
}

//
// Constructs one Huffman tree and assigns the code bit strings and lengths (build_tree).
//
fn buildTree(state: *DeflateState, desc: *TreeDesc) void {
    const tree = desc.dynTree;
    const stree = desc.statDesc.staticTree;
    const elems = desc.statDesc.elems;
    // largest code with non zero frequency
    var maxCode: i32 = -1;

    // Construct the initial heap, with least frequent element in heap[SMALLEST].
    state.heapLen = 0;
    state.heapMax = heap_size;

    var index: usize = 0;
    while (index < elems) : (index += 1) {
        if (tree[index].freqOrCode != 0) {
            state.heapLen += 1;
            maxCode = @intCast(index);
            state.heap[@intCast(state.heapLen)] = maxCode;
            state.depth[index] = 0;
        }
        else {
            tree[index].dadOrLen = 0;
        }
    }

    // The pkzip format requires that at least one distance code exists, and that at least one bit should be sent
    // even if there is only one possible code. So to avoid special checks later on we force at least two codes of
    // non zero frequency.
    while (state.heapLen < 2) {
        var node: i32 = 0;
        if (maxCode < 2) {
            maxCode += 1;
            node = maxCode;
        }
        state.heapLen += 1;
        state.heap[@intCast(state.heapLen)] = node;
        tree[@intCast(node)].freqOrCode = 1;
        state.depth[@intCast(node)] = 0;
        state.optLen -%= 1;
        if (stree) |staticTree| {
            state.staticLen -%= staticTree[@intCast(node)].dadOrLen;
        }
        // node is 0 or 1 so it does not have extra bits
    }
    desc.maxCode = maxCode;

    // The elements heap[heap_len/2+1 .. heap_len] are leaves of the tree, establish sub-heaps of increasing lengths:
    var heapIndex: i32 = @divTrunc(state.heapLen, 2);
    while (heapIndex >= 1) : (heapIndex -= 1) {
        pqdownheap(state, tree, heapIndex);
    }

    // Construct the Huffman tree by repeatedly combining the least two frequent nodes.
    // next internal node of the tree
    var node: i32 = @intCast(elems);
    while (true) {
        // n = node of least frequency
        const least = pqremove(state, tree);
        // m = node of next least frequency
        const nextLeast = state.heap[smallest];

        // keep the nodes sorted by frequency
        state.heapMax -= 1;
        state.heap[@intCast(state.heapMax)] = least;
        state.heapMax -= 1;
        state.heap[@intCast(state.heapMax)] = nextLeast;

        // Create a new node father of n and m
        const nodeIndex: usize = @intCast(node);
        const leastIndex: usize = @intCast(least);
        const nextLeastIndex: usize = @intCast(nextLeast);
        tree[nodeIndex].freqOrCode = tree[leastIndex].freqOrCode +% tree[nextLeastIndex].freqOrCode;
        state.depth[nodeIndex] = (if (state.depth[leastIndex] >= state.depth[nextLeastIndex]) state.depth[leastIndex] else state.depth[nextLeastIndex]) + 1;
        tree[leastIndex].dadOrLen = @intCast(node);
        tree[nextLeastIndex].dadOrLen = @intCast(node);

        // and insert the new node in the heap
        state.heap[smallest] = node;
        node += 1;
        pqdownheap(state, tree, smallest);

        if (state.heapLen < 2) {
            break;
        }
    }

    state.heapMax -= 1;
    state.heap[@intCast(state.heapMax)] = state.heap[smallest];

    // At this point, the fields freq and dad are set. We can now generate the bit lengths.
    genBitlen(state, desc);

    // The field len is now set, we can generate the bit codes
    genCodes(tree, maxCode, &state.blCount);
}

//
// Scans a literal or distance tree to determine the frequencies of the codes in the bit length tree (scan_tree).
//
fn scanTree(state: *DeflateState, tree: []CtData, maxCode: i32) void {
    // last emitted length
    var prevlen: i32 = -1;
    // length of next code
    var nextlen: i32 = tree[0].dadOrLen;
    // repeat count of the current code
    var count: i32 = 0;
    // max repeat count
    var maxCount: i32 = 7;
    // min repeat count
    var minCount: i32 = 4;

    if (nextlen == 0) {
        maxCount = 138;
        minCount = 3;
    }
    // guard
    tree[@intCast(maxCode + 1)].dadOrLen = 0xffff;

    var index: i32 = 0;
    while (index <= maxCode) : (index += 1) {
        const curlen = nextlen;
        nextlen = tree[@intCast(index + 1)].dadOrLen;
        count += 1;
        if (count < maxCount and curlen == nextlen) {
            continue;
        }
        else if (count < minCount) {
            state.blTree[@intCast(curlen)].freqOrCode +%= @intCast(count);
        }
        else if (curlen != 0) {
            if (curlen != prevlen) {
                state.blTree[@intCast(curlen)].freqOrCode +%= 1;
            }
            state.blTree[rep_3_6].freqOrCode +%= 1;
        }
        else if (count <= 10) {
            state.blTree[repz_3_10].freqOrCode +%= 1;
        }
        else {
            state.blTree[repz_11_138].freqOrCode +%= 1;
        }
        count = 0;
        prevlen = curlen;
        if (nextlen == 0) {
            maxCount = 138;
            minCount = 3;
        }
        else if (curlen == nextlen) {
            maxCount = 6;
            minCount = 3;
        }
        else {
            maxCount = 7;
            minCount = 4;
        }
    }
}

//
// Sends a literal or distance tree in compressed form, using the codes in bl_tree (send_tree).
//
fn sendTree(state: *DeflateState, tree: []const CtData, maxCode: i32) std.mem.Allocator.Error!void {
    // last emitted length
    var prevlen: i32 = -1;
    // length of next code
    var nextlen: i32 = tree[0].dadOrLen;
    // repeat count of the current code
    var count: i32 = 0;
    // max repeat count
    var maxCount: i32 = 7;
    // min repeat count
    var minCount: i32 = 4;

    // tree[max_code+1].Len = -1; guard already set
    if (nextlen == 0) {
        maxCount = 138;
        minCount = 3;
    }

    var index: i32 = 0;
    while (index <= maxCode) : (index += 1) {
        const curlen = nextlen;
        nextlen = tree[@intCast(index + 1)].dadOrLen;
        count += 1;
        if (count < maxCount and curlen == nextlen) {
            continue;
        }
        else if (count < minCount) {
            while (true) {
                try sendCode(state, @intCast(curlen), &state.blTree);
                count -= 1;
                if (count == 0) {
                    break;
                }
            }
        }
        else if (curlen != 0) {
            if (curlen != prevlen) {
                try sendCode(state, @intCast(curlen), &state.blTree);
                count -= 1;
            }
            try sendCode(state, rep_3_6, &state.blTree);
            try sendBits(state, @intCast(count - 3), 2);
        }
        else if (count <= 10) {
            try sendCode(state, repz_3_10, &state.blTree);
            try sendBits(state, @intCast(count - 3), 3);
        }
        else {
            try sendCode(state, repz_11_138, &state.blTree);
            try sendBits(state, @intCast(count - 11), 7);
        }
        count = 0;
        prevlen = curlen;
        if (nextlen == 0) {
            maxCount = 138;
            minCount = 3;
        }
        else if (curlen == nextlen) {
            maxCount = 6;
            minCount = 3;
        }
        else {
            maxCount = 7;
            minCount = 4;
        }
    }
}

//
// Constructs the Huffman tree for the bit lengths and returns the index in bl_order of the last bit length code to
// send (build_bl_tree).
//
fn buildBlTree(state: *DeflateState) i32 {
    // Determine the bit length frequencies for literal and distance trees
    scanTree(state, &state.dynLtree, state.lDesc.maxCode);
    scanTree(state, &state.dynDtree, state.dDesc.maxCode);

    // Build the bit length tree:
    buildTree(state, &state.blDesc);
    // opt_len now includes the length of the tree representations, except the lengths of the bit lengths codes and
    // the 5+5+4 bits for the counts.

    // Determine the number of bit length codes to send. The pkzip format requires that at least 4 bit length codes be
    // sent.
    var maxBlindex: i32 = bl_codes - 1;
    while (maxBlindex >= 3) : (maxBlindex -= 1) {
        if (state.blTree[bl_order[@intCast(maxBlindex)]].dadOrLen != 0) {
            break;
        }
    }
    // Update opt_len to include the bit length tree and counts
    state.optLen +%= @intCast(3 * (maxBlindex + 1) + 5 + 5 + 4);

    return maxBlindex;
}

//
// Sends the header for a block using dynamic Huffman trees: the counts, the lengths of the bit length codes, the
// literal tree and the distance tree (send_all_trees).
//
fn sendAllTrees(state: *DeflateState, lcodes: i32, dcodes: i32, blcodes: i32) std.mem.Allocator.Error!void {
    // not +255 as stated in appnote.txt
    try sendBits(state, @intCast(lcodes - 257), 5);
    try sendBits(state, @intCast(dcodes - 1), 5);
    // not -3 as stated in appnote.txt
    try sendBits(state, @intCast(blcodes - 4), 4);
    var rank: usize = 0;
    while (rank < blcodes) : (rank += 1) {
        try sendBits(state, state.blTree[bl_order[rank]].dadOrLen, 3);
    }

    // literal tree
    try sendTree(state, &state.dynLtree, lcodes - 1);

    // distance tree
    try sendTree(state, &state.dynDtree, dcodes - 1);
}

//
// Sends a stored block (_tr_stored_block).
//
fn trStoredBlock(state: *DeflateState, buffer: usize, storedLen: u64, last: bool) std.mem.Allocator.Error!void {
    // send block type
    try sendBits(state, (stored_block << 1) + @as(u64, @intFromBool(last)), 3);
    // with header
    try copyBlock(state, buffer, @truncate(storedLen), true);
}

//
// Flushes the bits in the bit buffer to pending output, leaving at most 7 bits (_tr_flush_bits).
//
fn trFlushBits(state: *DeflateState) std.mem.Allocator.Error!void {
    try biFlush(state);
}

//
// Determines the best encoding for the current block: dynamic trees, static trees or store, and outputs the encoded
// block (_tr_flush_block). buffer is the window offset of the block, or null if it is too old.
//
fn trFlushBlock(state: *DeflateState, buffer: ?usize, storedLen: u64, last: bool) std.mem.Allocator.Error!void {
    // Not ported: detect_data_type (it only sets strm->data_type, which does not change the output)

    // Construct the literal and distance trees
    buildTree(state, &state.lDesc);
    buildTree(state, &state.dDesc);
    // At this point, opt_len and static_len are the total bit lengths of the compressed block data, excluding the
    // tree representations.

    // Build the bit length tree for the above two trees, and get the index in bl_order of the last bit length code to send.
    const maxBlindex = buildBlTree(state);

    // Determine the best encoding. Compute the block lengths in bytes.
    var optLenb: u64 = (state.optLen +% 3 +% 7) >> 3;
    const staticLenb: u64 = (state.staticLen +% 3 +% 7) >> 3;

    if (staticLenb <= optLenb) {
        optLenb = staticLenb;
    }

    if (storedLen + 4 <= optLenb and buffer != null) {
        // 4: two words for the lengths
        try trStoredBlock(state, buffer.?, storedLen, last);
    }
    else if (staticLenb == optLenb) {
        try sendBits(state, (static_trees << 1) + @as(u64, @intFromBool(last)), 3);
        try compressBlock(state, &static_tables.staticLtree, &static_tables.staticDtree);
    }
    else {
        try sendBits(state, (dyn_trees << 1) + @as(u64, @intFromBool(last)), 3);
        try sendAllTrees(state, state.lDesc.maxCode + 1, state.dDesc.maxCode + 1, maxBlindex + 1);
        try compressBlock(state, &state.dynLtree, &state.dynDtree);
    }
    initBlock(state);

    if (last) {
        try biWindup(state);
    }
}

//
// Sends the block data compressed using the given Huffman trees (compress_block).
//
fn compressBlock(state: *DeflateState, ltree: []const CtData, dtree: []const CtData) std.mem.Allocator.Error!void {
    // running index in sym_buf
    var symIndex: usize = 0;

    if (state.symNext != 0) {
        while (true) {
            var dist: u32 = state.symBuf[symIndex];
            dist += @as(u32, state.symBuf[symIndex + 1]) << 8;
            var lc: u32 = state.symBuf[symIndex + 2];
            symIndex += 3;
            if (dist == 0) {
                // send a literal byte
                try sendCode(state, lc, ltree);
            }
            else {
                // Here, lc is the match length - MIN_MATCH
                var code: usize = static_tables.lengthCode[lc];
                // send the length code
                try sendCode(state, code + literals + 1, ltree);
                var extra = extra_lbits[code];
                if (extra != 0) {
                    lc -= static_tables.baseLength[code];
                    // send the extra length bits
                    try sendBits(state, lc, extra);
                }
                // dist is now the match distance - 1
                dist -= 1;
                code = dCode(dist);

                // send the distance code
                try sendCode(state, code, dtree);
                extra = extra_dbits[code];
                if (extra != 0) {
                    dist -= static_tables.baseDist[code];
                    // send the extra distance bits
                    try sendBits(state, dist, extra);
                }
            }
            if (symIndex >= state.symNext) {
                break;
            }
        }
    }

    try sendCode(state, end_block, ltree);
}

//
// Reverses the first len bits of a code (bi_reverse).
//
fn biReverse(codeValue: u32, length: u32) u32 {
    var code = codeValue;
    var remaining = length;
    var result: u32 = 0;
    while (true) {
        result |= code & 1;
        code >>= 1;
        result <<= 1;
        remaining -= 1;
        if (remaining == 0) {
            break;
        }
    }
    return result >> 1;
}

//
// Flushes the bit buffer, keeping at most 7 bits in it (bi_flush).
//
fn biFlush(state: *DeflateState) std.mem.Allocator.Error!void {
    while (state.biValid >= 16) {
        try putShort(state, @truncate(state.biBuf));
        state.biBuf >>= 16;
        state.biValid -= 16;
    }
    if (state.biValid >= 8) {
        try putByte(state, @truncate(state.biBuf));
        state.biBuf >>= 8;
        state.biValid -= 8;
    }
}

//
// Flushes the bit buffer and aligns the output on a byte boundary (bi_windup).
//
fn biWindup(state: *DeflateState) std.mem.Allocator.Error!void {
    while (state.biValid >= 16) {
        try putShort(state, @truncate(state.biBuf));
        state.biBuf >>= 16;
        state.biValid -= 16;
    }
    if (state.biValid > 8) {
        try putShort(state, @truncate(state.biBuf));
    }
    else if (state.biValid > 0) {
        try putByte(state, @truncate(state.biBuf));
    }
    state.biBuf = 0;
    state.biValid = 0;
}

//
// Copies a stored block, storing first the length and its one's complement (copy_block).
//
fn copyBlock(state: *DeflateState, buffer: usize, length: u32, header: bool) std.mem.Allocator.Error!void {
    // align on byte boundary
    try biWindup(state);

    if (header) {
        const storedLength: u16 = @truncate(length);
        try putShort(state, storedLength);
        try putShort(state, ~storedLength);
    }
    try state.output.appendSlice(state.allocator, state.window[buffer .. buffer + length]);
}

// ---------------------------------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------------------------------

//
// Compresses input with gzip at level 9, producing the same bytes as Bun's `zlib.gzipSync(input, { level: 9 })`.
// The returned memory belongs to the caller (written for arena allocators).
//
pub fn gzipLevel9(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    const state = try deflateInit(allocator, input);
    try deflate(state);
    const output = try state.output.toOwnedSlice(allocator);
    allocator.free(state.symBuf);
    allocator.free(state.head);
    allocator.free(state.prev);
    allocator.free(state.window);
    allocator.destroy(state);
    return output;
}
