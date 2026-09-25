//
// Gzip compression at level 9 that is byte-identical to Bun's `zlib.gzipSync(buffer, { level: 9 })`.
//
// This file has no TypeScript counterpart. It is a port of Bun 1.3.14's bundled zlib-ng 2.3.3
// (https://github.com/zlib-ng/zlib-ng at commit 12731092979c6d07f42da27da673a9f6c7b13586, the hash that
// `process.versions.zlib` prints under Bun 1.3.14), built the way Bun's scripts/build/deps/zlib.ts builds it: ZLIB_COMPAT,
// WITH_OPTIM, the default LIT_MEM symbol buffers and runtime selected SIMD kernels.
//
// zlib-ng picks SIMD kernels at run time (functable.c), but on the level 9 path none of them can change the output bytes:
// - compare256 (C, SSE2, AVX2, AVX-512 on x86_64, NEON on aarch64) always returns the index of the first differing byte
//   within 256 bytes, so every longest_match_slow_* variant generated from match_tpl.h finds the same matches. This port
//   uses compare256_64 (the C kernel).
// - slide_hash (C, SSE2, AVX2, NEON) always subtracts w_size with saturation at zero.
// - The CRC-32 kernels (braid, Chorba, PCLMULQDQ, VPCLMULQDQ, ARMv8 CRC32) all compute the same CRC-32 of the input.
// - The hash that feeds the hash chains at level 9 is the scalar rolling hash of insert_string_roll.c, which deflate.c
//   selects by level (lm_set_level) and not through the functable.
// So x86_64 and aarch64 produce the same bytes and a single port covers both. The only platform dependent byte is the
// gzip header OS byte (OS_CODE, see os_code below).
//
// Only what `gzipSync` at level 9 executes is ported: deflateInit2 with windowBits 15 + 16 (gzip), memLevel 8 and the
// default strategy, then deflate() with all input available and Z_FINISH (Bun's zlibBufferSync passes the whole buffer
// with the finish flush flag), which runs deflate_slow with longest_match_slow (max_chain_length 4096 > 1024). Bun drives
// deflate() with 16 KiB output chunks, but the compressed bytes do not depend on the output chunk size (deflate_slow only
// continues once the pending output has been flushed), so this port appends to a growable buffer. Function names follow
// the C names (camelCased) and appear in the order of deflate.c, deflate_p.h, deflate_slow.c, insert_string_roll.c,
// match_tpl.h, compare256_p.h, slide_hash_c.c, trees_emit.h and trees.c.
//

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------------------------------------------
// Constants (deflate.h, zutil.h, trees.h)
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
// Size of the bit buffer in bi_buf (BIT_BUF_SIZE).
//
const bit_buf_size = 64;

//
// End of block literal code (END_BLOCK).
//
const end_block = 256;

//
// All codes must not exceed MAX_BITS bits (MAX_BITS).
//
const max_bits = 15;

//
// Bit length codes must not exceed MAX_BL_BITS bits (MAX_BL_BITS).
//
const max_bl_bits = 7;

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
// The minimum match length mandated by the deflate standard (STD_MIN_MATCH).
//
const std_min_match = 3;

//
// The maximum match length mandated by the deflate standard (STD_MAX_MATCH).
//
const std_max_match = 258;

//
// The minimum wanted match length of deflate_slow (WANT_MIN_MATCH).
//
const want_min_match = 4;

//
// Minimum amount of lookahead, except at the end of the input file (MIN_LOOKAHEAD).
//
const min_lookahead = std_max_match + std_min_match + 1;

//
// Number of bytes after the end of data in the window to initialize (WIN_INIT).
//
const win_init = std_max_match;

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
// Number of elements in the hash table (HASH_SIZE; zlib-ng does not size it from memLevel).
//
const hash_size: u32 = 65536;

//
// memLevel used by Bun (DEF_MEM_LEVEL).
//
const mem_level = 8;

//
// Size of the literal and distance symbol buffers in symbols (lit_bufsize = 1 << (memLevel + 6)).
//
const lit_bufsize: u32 = 1 << (mem_level + 6);

//
// The symbol buffers are full when sym_next reaches this (sym_end with LIT_MEM).
//
const sym_end: u32 = lit_bufsize - 1;

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
// The gzip header OS byte (OS_CODE in zlib-ng's zutil.h). zlib-ng picks it at compile time from the platform Bun was
// built for: 10 when _WIN32 is defined (and not __CYGWIN__), 19 when __APPLE__ is defined and 3 (Unix) otherwise.
//
pub const os_code: u8 = switch (builtin.os.tag) {
    .macos => 19,
    .windows => 10,
    else => 3,
};

// ---------------------------------------------------------------------------------------------------------------
// Static tables (trees.h, trees_tbl.h)
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
// Size of the zng_dist_code table (DIST_CODE_LEN).
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
// The constant tables of trees_tbl.h.
//
const StaticTables = struct {
    // The static literal tree, including the codes 286 and 287 that are needed to build a canonical tree (static_ltree).
    staticLtree: [l_codes + 2]CtData,

    // The static distance tree (static_dtree).
    staticDtree: [d_codes]CtData,

    // Distance codes: the first 256 values are for distances 3 .. 258, the last 256 for the top 8 bits of 15 bit distances (zng_dist_code).
    distCode: [dist_code_len]u8,

    // Length code for each normalized match length, 0 == STD_MIN_MATCH (zng_length_code).
    lengthCode: [std_max_match - std_min_match + 1]u8,

    // First normalized length for each code, 0 = STD_MIN_MATCH (base_length).
    baseLength: [length_codes]u32,

    // First normalized distance for each code, 0 = distance of 1 (base_dist).
    baseDist: [d_codes]u32,
};

//
// Computes the tables that zlib-ng ships precomputed in trees_tbl.h, with the algorithm that generated them (zlib's
// tr_static_init). Evaluated at compile time.
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
    // zng_dist_code[256] and zng_dist_code[257] are never used (zero in trees_tbl.h).
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
        tables.staticDtree[index].freqOrCode = biReverse(@intCast(index), 5);
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

    // Sliding window of window_size bytes (window).
    window: []u8,

    // Link to older string with same hash index (prev).
    prev: []u16,

    // Heads of the hash chains or 0 (head).
    head: []u16,

    // Hash index of string to be inserted, the running value of the rolling hash (ins_h).
    insH: u32,

    // Window position at the beginning of the current output block; negative when the window is moved backwards (block_start).
    blockStart: i64,

    // Previous match (prev_match).
    prevMatch: u16,

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
    highWater: u32,

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

    // Buffer for distances (d_buf).
    dBuf: []u16,

    // Buffer for literals or lengths (l_buf).
    lBuf: []u8,

    // Running index in the symbol buffers (sym_next).
    symNext: u32,

    // Bit length of current block with optimal trees (opt_len).
    optLen: u64,

    // Bit length of current block with static trees (static_len).
    staticLen: u64,

    // Number of string matches in current block (matches).
    matches: u32,

    // Output bit buffer; bits are inserted starting at the bottom (bi_buf).
    biBuf: u64,

    // Number of valid bits in bi_buf; bi_windup can briefly take it below zero, as the int32_t in C (bi_valid).
    biValid: i32,
};

// ---------------------------------------------------------------------------------------------------------------
// deflate.c
// ---------------------------------------------------------------------------------------------------------------

//
// Creates the compression state (deflateInit2 with level 9, Z_DEFLATED, windowBits 31, memLevel 8 and
// Z_DEFAULT_STRATEGY, including alloc_deflate, followed by deflateReset).
//
fn deflateInit2(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!*DeflateState {
    const state = try allocator.create(DeflateState);
    state.allocator = allocator;
    state.input = input;
    state.nextIn = 0;
    state.totalIn = 0;
    state.output = .empty;

    // alloc_deflate: the window is zeroed so that every byte has a defined value; fillWindow zeroes the bytes C reads
    // past the data (high_water), so the zeroing does not change what longestMatchSlow sees.
    state.window = try allocator.alloc(u8, window_size);
    @memset(state.window, 0);
    state.prev = try allocator.alloc(u16, w_size);
    @memset(state.prev, 0);
    state.head = try allocator.alloc(u16, hash_size);
    state.dBuf = try allocator.alloc(u16, lit_bufsize);
    state.lBuf = try allocator.alloc(u8, lit_bufsize);

    // nothing written to s->window yet
    state.highWater = 0;

    deflateReset(state);
    return state;
}

//
// Resets the stream and the trees (deflateResetKeep; the gzip status, the CRC-32 and last_flush have no counterpart here).
//
fn deflateResetKeep(state: *DeflateState) void {
    state.totalIn = 0;
    zngTrInit(state);
}

//
// Resets the stream and the longest match state (deflateReset).
//
fn deflateReset(state: *DeflateState) void {
    deflateResetKeep(state);
    lmInit(state);
}

//
// Compresses the whole input as one gzip member (deflate called with Z_FINISH until Z_STREAM_END).
//
fn deflate(state: *DeflateState) std.mem.Allocator.Error!void {
    // gzip header
    try putByte(state, 31);
    try putByte(state, 139);
    try putByte(state, 8);
    try putUint32(state, 0);
    try putByte(state, 0);
    try putByte(state, gzip_extra_flags_level_9);
    try putByte(state, os_code);

    // Start a new block or continue the current one.
    try deflateSlow(state);

    // Write the trailer
    try putUint32(state, std.hash.Crc32.hash(state.input));
    try putUint32(state, @truncate(state.totalIn));
    try flushPending(state);
}

//
// Initializes the "longest match" routines for a new zlib stream (lm_init).
//
fn lmInit(state: *DeflateState) void {
    // CLEAR_HASH
    @memset(state.head, 0);

    // Set the default configuration parameters:
    // Not ported: lm_set_level (the level 9 row of configuration_table is the good_match, max_lazy_match, nice_match
    // and max_chain_length constants above, and because max_chain_length > 1024 it selects the rolling hash functions,
    // which this port calls directly: updateHashRoll, insertStringRoll and quickInsertStringRoll)

    state.strStart = 0;
    state.blockStart = 0;
    state.lookahead = 0;
    state.insert = 0;
    state.prevLength = 0;
    state.matchAvailable = false;
    state.matchStart = 0;
    state.insH = 0;
}

//
// Fills the window when the lookahead becomes insufficient. Updates strstart and lookahead (fill_window).
//
fn fillWindow(state: *DeflateState) void {
    const wsize = w_size;

    while (true) {
        // Amount of free space at the end of the window.
        var more: u32 = window_size - state.lookahead - state.strStart;

        // If the window is almost full and there is insufficient lookahead, move the upper half to the lower one to
        // make room in the upper half.
        if (state.strStart >= wsize + max_dist) {
            @memcpy(state.window[0..wsize], state.window[wsize .. 2 * wsize]);
            if (state.matchStart >= wsize) {
                state.matchStart -= wsize;
            }
            else {
                state.matchStart = 0;
                state.prevLength = 0;
            }
            // we now have strstart >= MAX_DIST
            state.strStart -= wsize;
            state.blockStart -= wsize;
            if (state.insert > state.strStart) {
                state.insert = state.strStart;
            }
            slideHashC(state);
            more += wsize;
        }
        if (state.nextIn == state.input.len) {
            break;
        }

        const bytesRead = readBuf(state, state.strStart + state.lookahead, more);
        state.lookahead += bytesRead;

        // Initialize the hash value now that we have some input:
        if (state.lookahead + state.insert >= std_min_match) {
            const str: u32 = state.strStart - state.insert;
            // max_chain_length > 1024 at level 9
            state.insH = updateHashRoll(state.window[str], state.window[str + 1]);
            var count: u32 = state.insert;
            if (state.lookahead == 1) {
                count -%= 1;
            }
            if (count > 0) {
                insertStringRoll(state, str, count);
                state.insert -= count;
            }
        }
        // If the whole input has less than STD_MIN_MATCH bytes, ins_h is garbage, but this is not important since
        // only literal bytes will be emitted.

        if (!(state.lookahead < min_lookahead and state.nextIn != state.input.len)) {
            break;
        }
    }

    // If the WIN_INIT bytes after the end of the current data have never been written, then zero those bytes in order
    // to avoid memory check reports of the use of uninitialized bytes by the longest match routines. Update the high
    // water mark for the next time through here. WIN_INIT is set to STD_MAX_MATCH since the longest match routines
    // allow scanning to strstart + STD_MAX_MATCH, ignoring lookahead.
    if (state.highWater < window_size) {
        const curr: u32 = state.strStart + state.lookahead;
        var init: u32 = 0;

        if (state.highWater < curr) {
            // Previous high water mark below current data -- zero WIN_INIT bytes or up to end of window, whichever is less.
            init = window_size - curr;
            if (init > win_init) {
                init = win_init;
            }
            @memset(state.window[curr .. curr + init], 0);
            state.highWater = curr + init;
        }
        else if (state.highWater < curr + win_init) {
            // High water mark at or above current data, but below current data plus WIN_INIT -- zero out to current
            // data plus WIN_INIT, or up to end of window, whichever is less.
            init = curr + win_init - state.highWater;
            if (init > window_size - state.highWater) {
                init = window_size - state.highWater;
            }
            @memset(state.window[state.highWater .. state.highWater + init], 0);
            state.highWater += init;
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// deflate_p.h
// ---------------------------------------------------------------------------------------------------------------

//
// Records a literal byte in the symbol buffers and returns true if the block must be flushed (zng_tr_tally_lit).
//
fn zngTrTallyLit(state: *DeflateState, literal: u8) bool {
    state.dBuf[state.symNext] = 0;
    state.lBuf[state.symNext] = literal;
    state.symNext += 1;
    state.dynLtree[literal].freqOrCode += 1;
    return state.symNext == sym_end;
}

//
// Records a match in the symbol buffers and returns true if the block must be flushed (zng_tr_tally_dist). dist is the
// distance of the matched string and len the match length - STD_MIN_MATCH.
//
fn zngTrTallyDist(state: *DeflateState, distance: u32, length: u32) bool {
    state.dBuf[state.symNext] = @truncate(distance);
    state.lBuf[state.symNext] = @truncate(length);
    state.symNext += 1;
    state.matches += 1;
    const dist = distance -% 1;

    state.dynLtree[@as(usize, static_tables.lengthCode[length]) + literals + 1].freqOrCode += 1;
    state.dynDtree[dCode(dist)].freqOrCode += 1;
    return state.symNext == sym_end;
}

//
// Flushes as much pending output as possible (flush_pending / flush_pending_inline). The output is never full here, so
// only the bit buffer flush (zng_tr_flush_bits) has an effect.
//
fn flushPending(state: *DeflateState) std.mem.Allocator.Error!void {
    try zngTrFlushBits(state);
}

//
// Reverses the first len bits of a code using bit manipulation (bi_reverse).
//
fn biReverse(code: u16, length: u32) u16 {
    const reversed: u16 = @as(u16, bitrev8(@truncate(code >> 8))) | (@as(u16, bitrev8(@truncate(code))) << 8);
    return reversed >> @intCast(16 - length);
}

//
// Reverses the bits of a byte (the bitrev8 macro of bi_reverse).
//
fn bitrev8(byte: u8) u8 {
    const product: u64 = (@as(u64, byte) *% 0x80200802) & 0x0884422110;
    return @truncate((product *% 0x0101010101) >> 32);
}

//
// Reads a new buffer from the input into window[bufferStart..] and updates the total number of bytes read (read_buf).
// The CRC-32 that crc32_fold_copy computes while copying is computed over the whole input when the trailer is
// written, which gives the same value.
//
fn readBuf(state: *DeflateState, bufferStart: u32, size: u32) u32 {
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
// Flushes the current block, with given end-of-file flag (FLUSH_BLOCK_ONLY, and FLUSH_BLOCK whose early return never
// happens because the output never fills up).
//
fn flushBlockOnly(state: *DeflateState, last: bool) std.mem.Allocator.Error!void {
    const buffer: ?u32 = if (state.blockStart >= 0) @intCast(state.blockStart) else null;
    const storedLen: u32 = @intCast(@as(i64, state.strStart) - state.blockStart);
    try zngTrFlushBlock(state, buffer, storedLen, last);
    state.blockStart = state.strStart;
    try flushPending(state);
}

// ---------------------------------------------------------------------------------------------------------------
// deflate_slow.c
// ---------------------------------------------------------------------------------------------------------------

//
// Compresses the whole input with lazy evaluation of matches: a match is finally adopted only if there is no better
// match at the next window position (deflate_slow, called with Z_FINISH, so need_more is never returned).
//
fn deflateSlow(state: *DeflateState) std.mem.Allocator.Error!void {
    // Process the input block.
    while (true) {
        // Make sure that we always have enough lookahead, except at the end of the input file. We need STD_MAX_MATCH
        // bytes for the next match, plus WANT_MIN_MATCH bytes to insert the string following the next match.
        if (state.lookahead < min_lookahead) {
            fillWindow(state);
            if (state.lookahead == 0) {
                // flush the current block
                break;
            }
        }

        // Insert the string window[strstart .. strstart+2] in the dictionary, and set hash_head to the head of the
        // hash chain:
        var hashHead: u16 = 0;
        if (state.lookahead >= want_min_match) {
            hashHead = quickInsertStringRoll(state, state.strStart);
        }

        // Find the longest match, discarding those <= prev_length.
        state.prevMatch = @truncate(state.matchStart);
        var matchLen: u32 = std_min_match - 1;
        const dist: i64 = @as(i64, state.strStart) - hashHead;

        if (dist <= max_dist and dist > 0 and state.prevLength < max_lazy_match and hashHead != 0) {
            // To simplify the code, we prevent matches with the string of window index 0 (in particular we have to
            // avoid a match of the string with itself at the start of the input file).
            matchLen = longestMatchSlow(state, hashHead);
            // longest_match() sets match_start

            // Not ported: the Z_FILTERED check (the strategy is Z_DEFAULT_STRATEGY)
        }
        // If there was a match at the previous step and the current match is not better, output the previous match:
        if (state.prevLength >= std_min_match and matchLen <= state.prevLength) {
            // Do not insert strings in hash table beyond this.
            const maxInsert: u32 = state.strStart +% state.lookahead -% std_min_match;

            const bflush = zngTrTallyDist(state, state.strStart - 1 - state.prevMatch, state.prevLength - std_min_match);

            // Insert in hash table all strings up to the end of the match. strstart-1 and strstart are already
            // inserted. If there is not enough lookahead, the last two strings are not inserted in the hash table.
            state.prevLength -= 1;
            state.lookahead -= state.prevLength;

            const movFwd: u32 = state.prevLength - 1;
            if (maxInsert > state.strStart) {
                var insertCnt: u32 = movFwd;
                if (insertCnt > maxInsert - state.strStart) {
                    insertCnt = maxInsert - state.strStart;
                }
                insertStringRoll(state, state.strStart + 1, insertCnt);
            }
            state.prevLength = 0;
            state.matchAvailable = false;
            state.strStart += movFwd + 1;

            if (bflush) {
                try flushBlockOnly(state, false);
            }
        }
        else if (state.matchAvailable) {
            // If there was no match at the previous position, output a single literal. If there was a match but the
            // current match is longer, truncate the previous match to a single literal.
            const bflush = zngTrTallyLit(state, state.window[state.strStart - 1]);
            if (bflush) {
                try flushBlockOnly(state, false);
            }
            state.prevLength = matchLen;
            state.strStart += 1;
            state.lookahead -= 1;
        }
        else {
            // There is no previous match to compare with, wait for the next step to decide.
            state.prevLength = matchLen;
            state.matchAvailable = true;
            state.strStart += 1;
            state.lookahead -= 1;
        }
    }
    if (state.matchAvailable) {
        _ = zngTrTallyLit(state, state.window[state.strStart - 1]);
        state.matchAvailable = false;
    }
    state.insert = if (state.strStart < std_min_match - 1) state.strStart else std_min_match - 1;
    // flush == Z_FINISH
    try flushBlockOnly(state, true);
}

// ---------------------------------------------------------------------------------------------------------------
// insert_string_roll.c (insert_string_tpl.h with the rolling hash)
// ---------------------------------------------------------------------------------------------------------------

//
// Shift of the rolling hash (HASH_SLIDE).
//
const hash_slide = 5;

//
// Mask of the rolling hash (HASH_CALC_MASK).
//
const hash_calc_mask: u32 = 32768 - 1;

//
// The rolling hash reads the third byte of the string (HASH_CALC_OFFSET).
//
const hash_calc_offset = std_min_match - 1;

//
// Updates a hash value with the given input byte (update_hash_roll).
//
fn updateHashRoll(hashValue: u32, value: u32) u32 {
    const updated = (hashValue << hash_slide) ^ @as(u8, @truncate(value));
    return updated & hash_calc_mask;
}

//
// Quick inserts string str in the dictionary and returns the previous head of the hash chain (quick_insert_string_roll).
//
fn quickInsertStringRoll(state: *DeflateState, str: u32) u16 {
    const value: u32 = state.window[str + hash_calc_offset];
    state.insH = ((state.insH << hash_slide) ^ @as(u8, @truncate(value)));
    state.insH &= hash_calc_mask;
    const hashMask = state.insH;

    const head = state.head[hashMask];
    if (head != str) {
        state.prev[str & w_mask] = head;
        state.head[hashMask] = @truncate(str);
    }
    return head;
}

//
// Inserts count strings starting at str in the dictionary (insert_string_roll).
//
fn insertStringRoll(state: *DeflateState, str: u32, count: u32) void {
    var index: u16 = @truncate(str);
    var position: u32 = str + hash_calc_offset;
    const end: u32 = position + count;
    while (position < end) : ({
        index +%= 1;
        position += 1;
    }) {
        const value: u32 = state.window[position];
        state.insH = ((state.insH << hash_slide) ^ @as(u8, @truncate(value)));
        state.insH &= hash_calc_mask;
        const hashMask = state.insH;

        const head = state.head[hashMask];
        if (head != index) {
            state.prev[index & w_mask] = head;
            state.head[hashMask] = index;
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// match_tpl.h (LONGEST_MATCH_SLOW)
// ---------------------------------------------------------------------------------------------------------------

//
// Returns the offset of the bytes that the quick check compares at the end of a match of length bestLen: it only
// extends an extra byte to find the next best match length (the `offset` computation of match_tpl.h).
//
fn matchEndOffset(bestLen: u32) u32 {
    var offset: u32 = bestLen - 1;
    if (bestLen >= 4) {
        offset -= 2;
        if (bestLen >= 8) {
            offset -= 4;
        }
    }
    return offset;
}

//
// Returns true if the size bytes at window[first..] equal the size bytes at window[second..] (zng_memcmp_2,
// zng_memcmp_4 and zng_memcmp_8 against the scan_start and scan_end values read at the scan position).
//
fn windowBytesEqual(state: *const DeflateState, first: usize, second: usize, size: usize) bool {
    return std.mem.eql(u8, state.window[first .. first + size], state.window[second .. second + size]);
}

//
// Sets match_start to the longest match starting at the given string and returns its length. Matches shorter or equal
// to prev_length are discarded, in which case the result is equal to prev_length and match_start is garbage. This is
// the LONGEST_MATCH_SLOW variant, which spends more time to attempt to find longer matches once a match has already
// been found (longest_match_slow).
//
fn longestMatchSlow(state: *DeflateState, curMatchStart: u16) u32 {
    const strstart: u32 = state.strStart;
    const scan: usize = strstart;
    var curMatch: u16 = curMatchStart;
    const lookahead: u32 = state.lookahead;
    // mbase_start is window - match_offset and mbase_end is mbase_start + offset.
    var matchOffset: u16 = 0;

    var bestLen: u32 = if (state.prevLength != 0) state.prevLength else std_min_match - 1;

    // Calculate read offset which should only extend an extra byte to find the next best match length.
    var offset: u32 = matchEndOffset(bestLen);

    // Do not waste too much time if we already have a good match
    var chainLength: u32 = max_chain_length;
    if (bestLen >= good_match) {
        chainLength >>= 2;
    }

    // Stop when cur_match becomes <= limit. To simplify the code, we prevent matches with the string of window index 0
    var limit: u16 = if (strstart > max_dist) @intCast(strstart - max_dist) else 0;
    const limitBase: u16 = limit;
    if (bestLen >= std_min_match) {
        // We're continuing search (lazy evaluation). Find a most distant chain starting from scan with index=1
        // (index=0 corresponds to cur_match). We cannot use s->prev[strstart+1,...] immediately, because these
        // strings are not yet inserted into the hash table.
        var hash: u32 = updateHashRoll(0, state.window[scan + 1]);
        hash = updateHashRoll(hash, state.window[scan + 2]);

        var index: u32 = 3;
        while (index <= bestLen) : (index += 1) {
            hash = updateHashRoll(hash, state.window[scan + index]);

            // If we're starting with best_len >= 3, we can use offset search.
            const position = state.head[hash];
            if (position < curMatch) {
                matchOffset = @intCast(index - 2);
                curMatch = position;
            }
        }

        // Update offset-dependent variables
        limit = limitBase + matchOffset;
        if (curMatch <= limit) {
            return breakMatching(state, bestLen);
        }
    }
    while (true) {
        if (curMatch >= strstart) {
            break;
        }

        // Skip to next match if the match length cannot increase or if the match length is less than 2.
        const compareSize: usize = if (bestLen < 4) 2 else if (bestLen >= 8) 8 else 4;
        while (true) {
            const matchBase: usize = curMatch - matchOffset;
            if (windowBytesEqual(state, matchBase + offset, scan + offset, compareSize) and windowBytesEqual(state, matchBase, scan, compareSize)) {
                break;
            }
            // GOTO_NEXT_CHAIN
            chainLength -= 1;
            if (chainLength != 0) {
                curMatch = state.prev[curMatch & w_mask];
                if (curMatch > limit) {
                    continue;
                }
            }
            return bestLen;
        }
        const len: u32 = compare256(state, scan + 2, @as(usize, curMatch - matchOffset) + 2) + 2;

        if (len > bestLen) {
            const matchStart: u32 = curMatch - matchOffset;
            state.matchStart = matchStart;

            // Do not look for better matches if the current match reaches or exceeds the end of the input.
            if (len >= lookahead) {
                return lookahead;
            }
            bestLen = len;
            if (bestLen >= nice_match) {
                return bestLen;
            }

            offset = matchEndOffset(bestLen);

            // Look for a better string offset
            if (len > std_min_match and matchStart + len < strstart) {
                // Go back to offset 0
                curMatch -= matchOffset;
                matchOffset = 0;
                var nextPos: u16 = curMatch;
                var index: u32 = 0;
                while (index <= len - std_min_match) : (index += 1) {
                    const position = state.prev[(@as(u32, curMatch) + index) & w_mask];
                    if (position < nextPos) {
                        // Hash chain is more distant, use it
                        if (position <= @as(u32, limitBase) + index) {
                            return breakMatching(state, bestLen);
                        }
                        nextPos = position;
                        matchOffset = @intCast(index);
                    }
                }
                // Switch cur_match to next_pos chain
                curMatch = nextPos;

                // Try hash head at len-(STD_MIN_MATCH-1) position to see if we could get a better cur_match at the end
                // of string. Using (STD_MIN_MATCH-1) lets us include one more byte into hash - the byte which will be
                // checked in main loop now, and which allows to grow match by 1.
                const scanEndstr: usize = scan + len - (std_min_match + 1);

                var hash: u32 = updateHashRoll(0, state.window[scanEndstr]);
                hash = updateHashRoll(hash, state.window[scanEndstr + 1]);
                hash = updateHashRoll(hash, state.window[scanEndstr + 2]);

                const position = state.head[hash];
                if (position < curMatch) {
                    matchOffset = @intCast(len - (std_min_match + 1));
                    if (position <= @as(u32, limitBase) + matchOffset) {
                        return breakMatching(state, bestLen);
                    }
                    curMatch = position;
                }

                // Update offset-dependent variables
                limit = limitBase + matchOffset;
                continue;
            }
        }
        // GOTO_NEXT_CHAIN
        chainLength -= 1;
        if (chainLength != 0) {
            curMatch = state.prev[curMatch & w_mask];
            if (curMatch > limit) {
                continue;
            }
        }
        return bestLen;
    }
    return bestLen;
}

//
// Returns the best match length capped at the lookahead (the break_matching label of longest_match_slow).
//
fn breakMatching(state: *const DeflateState, bestLen: u32) u32 {
    if (bestLen < state.lookahead) {
        return bestLen;
    }
    return state.lookahead;
}

// ---------------------------------------------------------------------------------------------------------------
// compare256_p.h
// ---------------------------------------------------------------------------------------------------------------

//
// Returns the number of equal leading bytes of window[first..] and window[second..], at most 256 (compare256_64, the
// kernel of compare256_c; the SSE2, AVX2, AVX-512 and NEON kernels return the same value).
//
fn compare256(state: *const DeflateState, first: usize, second: usize) u32 {
    var len: u32 = 0;
    var source0 = first;
    var source1 = second;

    while (true) {
        const sourceValue = std.mem.readInt(u64, state.window[source0..][0..8], .little);
        const matchValue = std.mem.readInt(u64, state.window[source1..][0..8], .little);

        const difference = sourceValue ^ matchValue;
        if (difference != 0) {
            const matchByte: u32 = @ctz(difference) / 8;
            return len + matchByte;
        }

        source0 += 8;
        source1 += 8;
        len += 8;
        if (len >= 256) {
            break;
        }
    }

    return 256;
}

// ---------------------------------------------------------------------------------------------------------------
// slide_hash_c.c
// ---------------------------------------------------------------------------------------------------------------

//
// Subtracts wsize from every entry of a hash table, saturating at zero (slide_hash_c_chain).
//
fn slideHashCChain(table: []u16, wsize: u16) void {
    for (table) |*entry| {
        const value = entry.*;
        entry.* = if (value >= wsize) value - wsize else 0;
    }
}

//
// Slides the hash table when sliding the window down (slide_hash_c; the SSE2, AVX2 and NEON kernels give the same result).
//
fn slideHashC(state: *DeflateState) void {
    const wsize: u16 = @intCast(w_size);

    slideHashCChain(state.head, wsize);
    slideHashCChain(state.prev, wsize);
}

// ---------------------------------------------------------------------------------------------------------------
// deflate.h and trees_emit.h
// ---------------------------------------------------------------------------------------------------------------

//
// Outputs a byte (put_byte).
//
fn putByte(state: *DeflateState, value: u8) std.mem.Allocator.Error!void {
    try state.output.append(state.allocator, value);
}

//
// Outputs a 16-bit value LSB first (put_short).
//
fn putShort(state: *DeflateState, value: u16) std.mem.Allocator.Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try state.output.appendSlice(state.allocator, &bytes);
}

//
// Outputs a 32-bit value LSB first (put_uint32).
//
fn putUint32(state: *DeflateState, value: u32) std.mem.Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try state.output.appendSlice(state.allocator, &bytes);
}

//
// Outputs a 64-bit value LSB first (put_uint64).
//
fn putUint64(state: *DeflateState, value: u64) std.mem.Allocator.Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try state.output.appendSlice(state.allocator, &bytes);
}

//
// Sends a value on a given number of bits. If there is not enough room in bi_buf, uses the valid bits from bi_buf and
// (64 - bi_valid) bits from value, leaving (width - (64 - bi_valid)) unused bits in value (send_bits).
//
fn sendBits(state: *DeflateState, value: u64, length: u32) std.mem.Allocator.Error!void {
    // The callers pass bi_valid to the macro as a uint32_t copy.
    const biValid: u32 = @intCast(state.biValid);
    const totalBits: u32 = biValid + length;
    if (totalBits < bit_buf_size and biValid < bit_buf_size) {
        state.biBuf |= value << @intCast(biValid);
        state.biValid = @intCast(totalBits);
    }
    else if (biValid >= bit_buf_size) {
        try putUint64(state, state.biBuf);
        state.biBuf = value;
        state.biValid = @intCast(length);
    }
    else {
        state.biBuf |= value << @intCast(biValid);
        try putUint64(state, state.biBuf);
        state.biBuf = value >> @intCast(bit_buf_size - biValid);
        state.biValid = @intCast(totalBits - bit_buf_size);
    }
}

//
// Sends the code of symbol code of the given tree (send_code).
//
fn sendCode(state: *DeflateState, code: usize, tree: []const CtData) std.mem.Allocator.Error!void {
    try sendBits(state, tree[code].freqOrCode, tree[code].dadOrLen);
}

//
// Flushes the bit buffer and aligns the output on a byte boundary (bi_windup).
//
fn biWindup(state: *DeflateState) std.mem.Allocator.Error!void {
    if (state.biValid > 56) {
        try putUint64(state, state.biBuf);
    }
    else {
        if (state.biValid > 24) {
            try putUint32(state, @truncate(state.biBuf));
            state.biBuf >>= 32;
            state.biValid -= 32;
        }
        if (state.biValid > 8) {
            try putShort(state, @truncate(state.biBuf));
            state.biBuf >>= 16;
            state.biValid -= 16;
        }
        if (state.biValid > 0) {
            try putByte(state, @truncate(state.biBuf));
        }
    }
    state.biBuf = 0;
    state.biValid = 0;
}

//
// Emits a literal code (zng_emit_lit / zng_tr_emit_lit).
//
fn zngEmitLit(state: *DeflateState, ltree: []const CtData, literal: usize) std.mem.Allocator.Error!void {
    try sendCode(state, literal, ltree);
}

//
// Emits a match: the length code and extra bits, then the distance code and extra bits, sent as one bit string
// (zng_emit_dist / zng_tr_emit_dist). lc is the match length - STD_MIN_MATCH and distance the match distance.
//
fn zngEmitDist(state: *DeflateState, ltree: []const CtData, dtree: []const CtData, matchLength: u32, distance: u32) std.mem.Allocator.Error!void {
    var lc = matchLength;
    var dist = distance;

    // Send the length code, len is the match length - STD_MIN_MATCH
    var code: usize = static_tables.lengthCode[lc];
    const lengthSymbol: usize = code + literals + 1;

    var matchBits: u64 = ltree[lengthSymbol].freqOrCode;
    var matchBitsLen: u32 = ltree[lengthSymbol].dadOrLen;
    var extra: u32 = extra_lbits[code];
    if (extra != 0) {
        lc -= static_tables.baseLength[code];
        matchBits |= @as(u64, lc) << @intCast(matchBitsLen);
        matchBitsLen += extra;
    }

    // dist is now the match distance - 1
    dist -= 1;
    code = dCode(dist);

    // Send the distance code
    matchBits |= @as(u64, dtree[code].freqOrCode) << @intCast(matchBitsLen);
    matchBitsLen += dtree[code].dadOrLen;
    extra = extra_dbits[code];
    if (extra != 0) {
        dist -= static_tables.baseDist[code];
        matchBits |= @as(u64, dist) << @intCast(matchBitsLen);
        matchBitsLen += extra;
    }

    try sendBits(state, matchBits, matchBitsLen);
}

//
// Emits the end of block code (zng_emit_end_block).
//
fn zngEmitEndBlock(state: *DeflateState, ltree: []const CtData) std.mem.Allocator.Error!void {
    try sendCode(state, end_block, ltree);
}

//
// Emits the start of a block: its type and the last block flag (zng_tr_emit_tree).
//
fn zngTrEmitTree(state: *DeflateState, blockType: u32, last: bool) std.mem.Allocator.Error!void {
    const headerBits: u32 = (blockType << 1) + @intFromBool(last);
    try sendBits(state, headerBits, 3);
}

//
// Aligns the bit buffer on a byte boundary (zng_tr_emit_align).
//
fn zngTrEmitAlign(state: *DeflateState) std.mem.Allocator.Error!void {
    try biWindup(state);
}

// ---------------------------------------------------------------------------------------------------------------
// trees.c
// ---------------------------------------------------------------------------------------------------------------

//
// Initializes the tree data structures for a new zlib stream (zng_tr_init).
//
fn zngTrInit(state: *DeflateState) void {
    state.lDesc = .{ .dynTree = &state.dynLtree, .maxCode = 0, .statDesc = &static_l_desc };
    state.dDesc = .{ .dynTree = &state.dynDtree, .maxCode = 0, .statDesc = &static_d_desc };
    state.blDesc = .{ .dynTree = &state.blTree, .maxCode = 0, .statDesc = &static_bl_desc };
    // The trees, the heap and the depths are zeroed like the C state; only their Freq fields are read before being set.
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

    // Initialize the first block of the first file:
    initBlock(state);
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
    state.matches = 0;
}

//
// Index within the heap array of least frequent node in the Huffman tree (SMALLEST).
//
const smallest = 1;

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
// Restores the heap property by moving down the tree starting at node k (pqdownheap).
//
fn pqdownheap(state: *DeflateState, tree: []const CtData, startNode: i32) void {
    var node = startNode;
    // left son of k
    var son = node << 1;
    const value = state.heap[@intCast(node)];
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
        tree[node].dadOrLen = @intCast(bits);
        // We overwrite tree[n].Dad which is no longer needed

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
                state.optLen +%= @as(u64, bits) * tree[nodeIndex].freqOrCode;
                state.optLen -%= @as(u64, tree[nodeIndex].dadOrLen) * tree[nodeIndex].freqOrCode;
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
        code = (code + blCount[bits - 1]) << 1;
        nextCode[bits] = @truncate(code);
    }

    var index: usize = 0;
    while (@as(i32, @intCast(index)) <= maxCode) : (index += 1) {
        const len = tree[index].dadOrLen;
        if (len == 0) {
            continue;
        }
        // Now reverse the bits
        tree[index].freqOrCode = biReverse(nextCode[len], len);
        nextCode[len] +%= 1;
    }
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
    var count: u16 = 0;
    // max repeat count
    var maxCount: u16 = 7;
    // min repeat count
    var minCount: u16 = 4;

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
            state.blTree[@intCast(curlen)].freqOrCode +%= count;
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
    // sent. (appnote.txt says 3 but the actual value used is 4.)
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
// Sends a stored block (zng_tr_stored_block). buffer is the window offset of the block.
//
fn zngTrStoredBlock(state: *DeflateState, buffer: u32, storedLen: u32, last: bool) std.mem.Allocator.Error!void {
    // send block type
    try zngTrEmitTree(state, stored_block, last);
    // align on byte boundary
    try zngTrEmitAlign(state);
    const storedLength: u16 = @truncate(storedLen);
    try putShort(state, storedLength);
    try putShort(state, ~storedLength);
    if (storedLen != 0) {
        try state.output.appendSlice(state.allocator, state.window[buffer .. buffer + storedLen]);
    }
}

//
// Determines the best encoding for the current block: dynamic trees, static trees or store, and writes out the encoded
// block (zng_tr_flush_block). buffer is the window offset of the block, or null if it is too old.
//
fn zngTrFlushBlock(state: *DeflateState, buffer: ?u32, storedLen: u32, last: bool) std.mem.Allocator.Error!void {
    // opt_len and static_len in bytes
    var optLenb: u64 = 0;
    var staticLenb: u64 = 0;
    // index of last bit length code of non zero freq
    var maxBlindex: i32 = 0;

    // Build the Huffman trees unless a stored block is forced
    if (state.symNext == 0) {
        // Emit an empty static tree block with no codes
        optLenb = 0;
        staticLenb = 0;
        state.staticLen = 7;
    }
    else {
        // level > 0
        // Not ported: detect_data_type (it only sets strm->data_type, which does not change the output)

        // Construct the literal and distance trees
        buildTree(state, &state.lDesc);
        buildTree(state, &state.dDesc);
        // At this point, opt_len and static_len are the total bit lengths of the compressed block data, excluding the
        // tree representations.

        // Build the bit length tree for the above two trees, and get the index in bl_order of the last bit length code
        // to send.
        maxBlindex = buildBlTree(state);

        // Determine the best encoding. Compute the block lengths in bytes.
        optLenb = (state.optLen +% 3 +% 7) >> 3;
        staticLenb = (state.staticLen +% 3 +% 7) >> 3;

        // The strategy is not Z_FIXED
        if (staticLenb <= optLenb) {
            optLenb = staticLenb;
        }
    }

    if (@as(u64, storedLen) + 4 <= optLenb and buffer != null) {
        // 4: two words for the lengths
        try zngTrStoredBlock(state, buffer.?, storedLen, last);
    }
    else if (staticLenb == optLenb) {
        try zngTrEmitTree(state, static_trees, last);
        try compressBlock(state, &static_tables.staticLtree, &static_tables.staticDtree);
    }
    else {
        try zngTrEmitTree(state, dyn_trees, last);
        try sendAllTrees(state, state.lDesc.maxCode + 1, state.dDesc.maxCode + 1, maxBlindex + 1);
        try compressBlock(state, &state.dynLtree, &state.dynDtree);
    }

    initBlock(state);
    if (last) {
        try zngTrEmitAlign(state);
    }
}

//
// Sends the block data compressed using the given Huffman trees (compress_block).
//
fn compressBlock(state: *DeflateState, ltree: []const CtData, dtree: []const CtData) std.mem.Allocator.Error!void {
    // running index in symbol buffers
    var symIndex: usize = 0;
    const symNext = state.symNext;

    if (symNext != 0) {
        while (true) {
            const dist: u32 = state.dBuf[symIndex];
            const lc: u32 = state.lBuf[symIndex];
            symIndex += 1;
            if (dist == 0) {
                try zngEmitLit(state, ltree, lc);
            }
            else {
                try zngEmitDist(state, ltree, dtree, lc, dist);
            }
            // literal or match pair ?
            if (symIndex >= symNext) {
                break;
            }
        }
    }

    try zngEmitEndBlock(state, ltree);
}

//
// Flushes the bit buffer, keeping at most 7 bits in it (zng_tr_flush_bits).
//
fn zngTrFlushBits(state: *DeflateState) std.mem.Allocator.Error!void {
    if (state.biValid >= 48) {
        try putUint32(state, @truncate(state.biBuf));
        try putShort(state, @truncate(state.biBuf >> 32));
        state.biBuf >>= 48;
        state.biValid -= 48;
    }
    else if (state.biValid >= 32) {
        try putUint32(state, @truncate(state.biBuf));
        state.biBuf >>= 32;
        state.biValid -= 32;
    }
    if (state.biValid >= 16) {
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
// Maps a distance - 1 to a distance code (d_code).
//
fn dCode(dist: u32) usize {
    if (dist < 256) {
        return static_tables.distCode[dist];
    }
    return static_tables.distCode[256 + (dist >> 7)];
}

// ---------------------------------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------------------------------

//
// Compresses input with gzip at level 9, producing the same bytes as Bun's `zlib.gzipSync(input, { level: 9 })`.
// The returned memory belongs to the caller (written for arena allocators).
//
pub fn gzipLevel9(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    const state = try deflateInit2(allocator, input);
    try deflate(state);
    const output = try state.output.toOwnedSlice(allocator);
    allocator.free(state.lBuf);
    allocator.free(state.dBuf);
    allocator.free(state.head);
    allocator.free(state.prev);
    allocator.free(state.window);
    allocator.destroy(state);
    return output;
}
