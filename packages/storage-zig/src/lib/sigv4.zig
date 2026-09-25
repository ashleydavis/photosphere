const std = @import("std");

//
// AWS Signature Version 4 request signing.
// No TypeScript counterpart: the TypeScript storage package uses the AWS SDK v3, which signs every request itself.
// See https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
//

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

//
// The signing algorithm name.
//
pub const ALGORITHM = "AWS4-HMAC-SHA256";

//
// The payload hash of an empty body.
//
pub const EMPTY_PAYLOAD_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

//
// The credentials used to sign a request.
//
pub const ICredentials = struct {
    // The access key id.
    accessKeyId: []const u8,

    // The secret access key.
    secretAccessKey: []const u8,

    // The session token of temporary credentials (sent as x-amz-security-token), if any.
    sessionToken: ?[]const u8,
};

//
// A query string parameter (name and value are not encoded).
//
pub const IQueryParameter = struct {
    // The parameter name.
    name: []const u8,

    // The parameter value (empty for a parameter without a value such as "?uploads").
    value: []const u8,
};

//
// A request header.
//
pub const IHeader = struct {
    // The header name (any case).
    name: []const u8,

    // The header value.
    value: []const u8,
};

//
// The parts of a request that are signed.
//
pub const ISignableRequest = struct {
    // The HTTP method, e.g. "GET".
    method: []const u8,

    // The canonical URI: the URI-encoded absolute path (S3 encodes the path once; other services encode it twice).
    canonicalUri: []const u8,

    // The query string parameters.
    query: []const IQueryParameter,

    // The headers to sign (must include host and x-amz-date).
    headers: []const IHeader,

    // The hex SHA-256 of the payload (or "UNSIGNED-PAYLOAD").
    payloadHash: []const u8,

    // The region, e.g. "us-east-1".
    region: []const u8,

    // The service, e.g. "s3".
    service: []const u8,

    // The request time in ISO 8601 basic format, e.g. "20130524T000000Z" (the x-amz-date header).
    amzDate: []const u8,
};

//
// The result of signing a request.
//
pub const ISignature = struct {
    // The canonical request that was hashed.
    canonicalRequest: []const u8,

    // The string that was signed.
    stringToSign: []const u8,

    // The semicolon separated list of signed header names.
    signedHeaders: []const u8,

    // The hex signature.
    signature: []const u8,

    // The value of the Authorization header.
    authorization: []const u8,
};

//
// Returns the lowercase hex SHA-256 of data.
//
pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

//
// Returns true for the characters that URI encoding leaves as they are (RFC 3986 unreserved characters).
//
fn isUnreserved(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '-' or character == '.' or character == '_' or character == '~';
}

//
// URI-encodes a string the way SigV4 requires: every byte except the unreserved characters becomes %XX (uppercase hex).
// When encodeSlash is false, "/" is kept (used for object key paths).
//
pub fn uriEncode(allocator: std.mem.Allocator, text: []const u8, encodeSlash: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    for (text) |character| {
        if (isUnreserved(character) or (character == '/' and !encodeSlash)) {
            try output.append(allocator, character);
        }
        else {
            try output.print(allocator, "%{X:0>2}", .{character});
        }
    }
    return output.toOwnedSlice(allocator);
}

//
// An encoded query parameter, for sorting.
//
const EncodedParameter = struct {
    // The encoded name.
    name: []const u8,

    // The encoded value.
    value: []const u8,

    //
    // Sorts by name and then by value (byte order).
    //
    fn lessThan(context: void, left: EncodedParameter, right: EncodedParameter) bool {
        _ = context;
        const nameOrder = std.mem.order(u8, left.name, right.name);
        if (nameOrder != .eq) {
            return nameOrder == .lt;
        }
        return std.mem.order(u8, left.value, right.value) == .lt;
    }
};

//
// Builds the canonical query string: encoded name=value pairs sorted by name, joined by "&".
//
pub fn canonicalQueryString(allocator: std.mem.Allocator, query: []const IQueryParameter) ![]u8 {
    const encoded = try allocator.alloc(EncodedParameter, query.len);
    for (query, 0..) |parameter, index| {
        encoded[index] = .{
            .name = try uriEncode(allocator, parameter.name, true),
            .value = try uriEncode(allocator, parameter.value, true),
        };
    }
    std.mem.sort(EncodedParameter, encoded, {}, EncodedParameter.lessThan);
    var output: std.ArrayList(u8) = .empty;
    for (encoded, 0..) |parameter, index| {
        if (index > 0) {
            try output.append(allocator, '&');
        }
        try output.appendSlice(allocator, parameter.name);
        try output.append(allocator, '=');
        try output.appendSlice(allocator, parameter.value);
    }
    return output.toOwnedSlice(allocator);
}

//
// A header prepared for signing.
//
const CanonicalHeader = struct {
    // The lowercase name.
    name: []const u8,

    // The trimmed value with sequential spaces collapsed.
    value: []const u8,

    //
    // Sorts by name.
    //
    fn lessThan(context: void, left: CanonicalHeader, right: CanonicalHeader) bool {
        _ = context;
        return std.mem.order(u8, left.name, right.name) == .lt;
    }
};

//
// Trims a header value and collapses runs of spaces into one space.
//
fn canonicalHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    var output: std.ArrayList(u8) = .empty;
    var previousWasSpace = false;
    for (trimmed) |character| {
        const isSpace = character == ' ' or character == '\t';
        if (isSpace) {
            if (!previousWasSpace) {
                try output.append(allocator, ' ');
            }
        }
        else {
            try output.append(allocator, character);
        }
        previousWasSpace = isSpace;
    }
    return output.toOwnedSlice(allocator);
}

//
// Builds the canonical request.
//
pub fn canonicalRequest(allocator: std.mem.Allocator, request: ISignableRequest, signedHeadersOut: *[]const u8) ![]u8 {
    const headers = try allocator.alloc(CanonicalHeader, request.headers.len);
    for (request.headers, 0..) |header, index| {
        headers[index] = .{
            .name = try std.ascii.allocLowerString(allocator, header.name),
            .value = try canonicalHeaderValue(allocator, header.value),
        };
    }
    std.mem.sort(CanonicalHeader, headers, {}, CanonicalHeader.lessThan);

    var signedHeaders: std.ArrayList(u8) = .empty;
    var canonicalHeaders: std.ArrayList(u8) = .empty;
    for (headers, 0..) |header, index| {
        if (index > 0) {
            try signedHeaders.append(allocator, ';');
        }
        try signedHeaders.appendSlice(allocator, header.name);
        try canonicalHeaders.print(allocator, "{s}:{s}\n", .{ header.name, header.value });
    }
    signedHeadersOut.* = try signedHeaders.toOwnedSlice(allocator);

    const queryString = try canonicalQueryString(allocator, request.query);
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        request.method,
        request.canonicalUri,
        queryString,
        canonicalHeaders.items,
        signedHeadersOut.*,
        request.payloadHash,
    });
}

//
// Derives the signing key: HMAC chain of the date, region, service and "aws4_request".
//
pub fn deriveSigningKey(allocator: std.mem.Allocator, secretAccessKey: []const u8, date: []const u8, region: []const u8, service: []const u8) ![32]u8 {
    const secret = try std.mem.concat(allocator, u8, &.{ "AWS4", secretAccessKey });
    var dateKey: [32]u8 = undefined;
    HmacSha256.create(&dateKey, date, secret);
    var regionKey: [32]u8 = undefined;
    HmacSha256.create(&regionKey, region, &dateKey);
    var serviceKey: [32]u8 = undefined;
    HmacSha256.create(&serviceKey, service, &regionKey);
    var signingKey: [32]u8 = undefined;
    HmacSha256.create(&signingKey, "aws4_request", &serviceKey);
    return signingKey;
}

//
// Signs a request and returns the Authorization header value (and the intermediate values, for tests).
//
pub fn sign(allocator: std.mem.Allocator, credentials: ICredentials, request: ISignableRequest) !ISignature {
    var signedHeaders: []const u8 = "";
    const canonical = try canonicalRequest(allocator, request, &signedHeaders);
    const date = request.amzDate[0..8];
    const scope = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/aws4_request", .{ date, request.region, request.service });
    const canonicalHash = sha256Hex(canonical);
    const stringToSign = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}", .{ ALGORITHM, request.amzDate, scope, &canonicalHash });
    const signingKey = try deriveSigningKey(allocator, credentials.secretAccessKey, date, request.region, request.service);
    var signatureBytes: [32]u8 = undefined;
    HmacSha256.create(&signatureBytes, stringToSign, &signingKey);
    const signature = try allocator.dupe(u8, &std.fmt.bytesToHex(signatureBytes, .lower));
    const authorization = try std.fmt.allocPrint(allocator, "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{
        ALGORITHM,
        credentials.accessKeyId,
        scope,
        signedHeaders,
        signature,
    });
    return .{
        .canonicalRequest = canonical,
        .stringToSign = stringToSign,
        .signedHeaders = signedHeaders,
        .signature = signature,
        .authorization = authorization,
    };
}

//
// Formats a time (milliseconds since the Unix epoch) as the x-amz-date value, e.g. "20130524T000000Z".
//
pub fn formatAmzDate(timestampMs: i64) [16]u8 {
    const epochSeconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(timestampMs, 1000)) };
    const yearDay = epochSeconds.getEpochDay().calculateYearDay();
    const monthDay = yearDay.calculateMonthDay();
    const daySeconds = epochSeconds.getDaySeconds();
    var buffer: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yearDay.year,
        monthDay.month.numeric(),
        @as(u32, monthDay.day_index) + 1,
        daySeconds.getHoursIntoDay(),
        daySeconds.getMinutesIntoHour(),
        daySeconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return buffer;
}
