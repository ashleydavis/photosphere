const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const sigv4 = @import("sigv4.zig");

//
// A minimal S3 client over std.http.Client. No TypeScript counterpart: it stands in for the parts of
// `@aws-sdk/client-s3` (S3Client and the commands CloudStorage sends) and `@aws-sdk/lib-storage` (Upload) that
// CloudStorage uses. Command inputs and outputs keep the SDK's PascalCase field names so CloudStorage reads like the
// TypeScript. Errors returned by S3 are thrown with the S3 error code as the error name (utils errors.lastErrorName(),
// the SDK's `err.name`) and the HTTP status in lastHttpStatusCode() (the SDK's `err.$metadata.httpStatusCode`).
//

const errors = utils.errors;

//
// The HTTP status code of the most recent S3 error thrown on this thread (0 when the request did not get a response).
//
threadlocal var last_http_status_code: u16 = 0;

//
// Gets the HTTP status code of the most recent S3 error thrown on this thread (TypeScript: `err.$metadata?.httpStatusCode`).
//
pub fn lastHttpStatusCode() u16 {
    return last_http_status_code;
}

//
// Configuration of the client (the subset of the SDK's S3ClientConfig that CloudStorage sets).
//
pub const IS3ClientConfig = struct {
    // A custom endpoint URL such as "https://nyc3.digitaloceanspaces.com" (null for AWS).
    endpoint: ?[]const u8,

    // The region (null to use the AWS_REGION environment variable like the SDK).
    region: ?[]const u8,

    // The credentials (null to use the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN environment
    // variables like the SDK's default provider chain; shared config files are not read).
    credentials: ?sigv4.ICredentials,
};

//
// A request to S3.
//
pub const S3Request = struct {
    // The HTTP method.
    method: std.http.Method,

    // The bucket.
    bucket: []const u8,

    // The object key (null for a request on the bucket).
    key: ?[]const u8,

    // The query string parameters.
    query: []const sigv4.IQueryParameter,

    // Extra headers (all of them are signed).
    headers: []const sigv4.IHeader,

    // The body (null for none).
    body: ?[]const u8,
};

//
// A response from S3.
//
pub const S3Response = struct {
    // The HTTP status code.
    status: u16,

    // The response headers.
    headers: []const sigv4.IHeader,

    // The response body.
    body: []u8,

    //
    // Gets a response header by name (case-insensitive).
    //
    pub fn header(self: S3Response, name: []const u8) ?[]const u8 {
        for (self.headers) |responseHeader| {
            if (std.ascii.eqlIgnoreCase(responseHeader.name, name)) {
                return responseHeader.value;
            }
        }
        return null;
    }
};

//
// Where requests are sent: the parsed endpoint.
//
pub const IEndpoint = struct {
    // "http" or "https".
    scheme: []const u8,

    // The host name (or IP address).
    hostname: []const u8,

    // The port given in the endpoint URL (null for the scheme's default port).
    port: ?u16,

    // The path of the endpoint URL without a trailing slash (usually empty).
    basePath: []const u8,
};

//
// The URL parts of one request.
//
pub const IRequestLocation = struct {
    // The endpoint the request goes to.
    endpoint: IEndpoint,

    // The host name the request goes to (the bucket is prepended for virtual-hosted-style requests).
    hostname: []const u8,

    // The value of the Host header (host name plus the port when the endpoint gives one).
    host: []const u8,

    // The URI-encoded path.
    path: []const u8,
};

//
// Parses the endpoint URL, or builds the AWS endpoint for the region when there is none.
//
pub fn resolveEndpoint(allocator: std.mem.Allocator, endpoint: ?[]const u8, region: []const u8) !IEndpoint {
    const endpointUrl = endpoint orelse {
        return .{
            .scheme = "https",
            .hostname = try std.fmt.allocPrint(allocator, "s3.{s}.amazonaws.com", .{region}),
            .port = null,
            .basePath = "",
        };
    };
    const uri = std.Uri.parse(endpointUrl) catch {
        return errors.throwError("Invalid endpoint: {s}", .{endpointUrl});
    };
    const hostComponent = uri.host orelse {
        return errors.throwError("Invalid endpoint: {s}", .{endpointUrl});
    };
    var basePath = try uri.path.toRawMaybeAlloc(allocator);
    while (std.mem.endsWith(u8, basePath, "/")) {
        basePath = basePath[0 .. basePath.len - 1];
    }
    return .{
        .scheme = uri.scheme,
        .hostname = try hostComponent.toRawMaybeAlloc(allocator),
        .port = uri.port,
        .basePath = basePath,
    };
}

//
// Returns true when the host is an IP address (the SDK then uses path-style requests).
//
fn isIpAddress(hostname: []const u8) bool {
    if (std.mem.indexOfScalar(u8, hostname, ':') != null) {
        return true;
    }
    var parts = std.mem.splitScalar(u8, hostname, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (part.len == 0 or part.len > 3) {
            return false;
        }
        for (part) |character| {
            if (!std.ascii.isDigit(character)) {
                return false;
            }
        }
    }
    return count == 4;
}

//
// Returns true when the bucket name can be used as a host name label (the SDK's isVirtualHostableS3Bucket).
// Dots are only allowed for plain HTTP, because they break TLS certificate matching.
//
pub fn isVirtualHostableBucket(bucket: []const u8, allowDots: bool) bool {
    if (bucket.len < 3 or bucket.len > 63) {
        return false;
    }
    if (!std.ascii.isAlphanumeric(bucket[0]) or !std.ascii.isAlphanumeric(bucket[bucket.len - 1])) {
        return false;
    }
    for (bucket) |character| {
        const isValid = std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-' or (character == '.' and allowDots);
        if (!isValid) {
            return false;
        }
    }
    if (std.mem.indexOf(u8, bucket, "..") != null) {
        return false;
    }
    return !isIpAddress(bucket);
}

//
// Works out the host and path of a request.
// Like the SDK (which CloudStorage creates without forcePathStyle): virtual-hosted-style ("bucket.host/key") unless
// the endpoint host is an IP address or the bucket name is not a valid host name label, in which case path-style
// ("host/bucket/key") is used.
//
pub fn resolveRequestLocation(allocator: std.mem.Allocator, endpoint: IEndpoint, bucket: []const u8, key: ?[]const u8) !IRequestLocation {
    const encodedKey = if (key) |objectKey| try sigv4.uriEncode(allocator, objectKey, false) else "";
    const allowDots = std.mem.eql(u8, endpoint.scheme, "http");
    const pathStyle = isIpAddress(endpoint.hostname) or !isVirtualHostableBucket(bucket, allowDots);
    var hostname = endpoint.hostname;
    var path: []const u8 = undefined;
    if (pathStyle) {
        const encodedBucket = try sigv4.uriEncode(allocator, bucket, true);
        if (key != null) {
            path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ endpoint.basePath, encodedBucket, encodedKey });
        }
        else {
            path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ endpoint.basePath, encodedBucket });
        }
    }
    else {
        hostname = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ bucket, endpoint.hostname });
        path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ endpoint.basePath, encodedKey });
    }
    var host = hostname;
    if (endpoint.port) |port| {
        host = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ hostname, port });
    }
    return .{
        .endpoint = endpoint,
        .hostname = hostname,
        .host = host,
        .path = path,
    };
}

//
// S3 error codes that are thrown with their own name (error names must be static strings).
//
const known_error_names = [_][]const u8{
    "NoSuchKey",
    "NotFound",
    "NoSuchBucket",
    "NoSuchUpload",
    "AccessDenied",
    "Forbidden",
    "BadRequest",
    "PreconditionFailed",
    "ConditionalRequestConflict",
    "InvalidRange",
    "InvalidAccessKeyId",
    "SignatureDoesNotMatch",
    "InvalidArgument",
    "InvalidRequest",
    "InvalidPart",
    "InvalidPartOrder",
    "EntityTooSmall",
    "InternalError",
    "SlowDown",
    "ServiceUnavailable",
    "UnknownError",
};

//
// Maps an S3 error code to a static error name.
//
fn staticErrorName(code: []const u8) []const u8 {
    for (known_error_names) |name| {
        if (std.mem.eql(u8, name, code)) {
            return name;
        }
    }
    return "S3ServiceException";
}

//
// The error name the SDK uses for an error response without a body (for example a HEAD request).
//
fn errorNameForStatus(status: u16) []const u8 {
    return switch (status) {
        400 => "BadRequest",
        403 => "Forbidden",
        404 => "NotFound",
        412 => "PreconditionFailed",
        else => "UnknownError",
    };
}

//
// Decodes the XML entities of a text node.
//
pub fn xmlDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '&') {
            try output.append(allocator, text[index]);
            index += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, index, ';') orelse {
            try output.append(allocator, text[index]);
            index += 1;
            continue;
        };
        const entity = text[index + 1 .. end];
        if (std.mem.eql(u8, entity, "amp")) {
            try output.append(allocator, '&');
        }
        else if (std.mem.eql(u8, entity, "lt")) {
            try output.append(allocator, '<');
        }
        else if (std.mem.eql(u8, entity, "gt")) {
            try output.append(allocator, '>');
        }
        else if (std.mem.eql(u8, entity, "quot")) {
            try output.append(allocator, '"');
        }
        else if (std.mem.eql(u8, entity, "apos")) {
            try output.append(allocator, '\'');
        }
        else if (entity.len > 1 and entity[0] == '#') {
            const codePoint = if (entity[1] == 'x' or entity[1] == 'X')
                std.fmt.parseInt(u21, entity[2..], 16) catch 0xFFFD
            else
                std.fmt.parseInt(u21, entity[1..], 10) catch 0xFFFD;
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codePoint, &encoded) catch 0;
            try output.appendSlice(allocator, encoded[0..length]);
        }
        else {
            try output.appendSlice(allocator, text[index .. end + 1]);
        }
        index = end + 1;
    }
    return output.toOwnedSlice(allocator);
}

//
// Encodes text for an XML text node.
//
pub fn xmlEncode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    for (text) |character| {
        switch (character) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&apos;"),
            else => try output.append(allocator, character),
        }
    }
    return output.toOwnedSlice(allocator);
}

//
// Returns the raw inner text of every <tag>...</tag> element in the XML (elements of the same tag must not nest).
//
pub fn xmlElements(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) ![]const []const u8 {
    const openTag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    const closeTag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    var elements: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, xml, index, openTag)) |start| {
        const contentStart = start + openTag.len;
        const end = std.mem.indexOfPos(u8, xml, contentStart, closeTag) orelse {
            break;
        };
        try elements.append(allocator, xml[contentStart..end]);
        index = end + closeTag.len;
    }
    return elements.toOwnedSlice(allocator);
}

//
// Returns the decoded text of the first <tag> element, or null when there is none.
//
pub fn xmlText(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) !?[]const u8 {
    const elements = try xmlElements(allocator, xml, tag);
    if (elements.len == 0) {
        return null;
    }
    return try xmlDecode(allocator, elements[0]);
}

//
// The month abbreviations used by HTTP dates.
//
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

//
// Returns the number of days from 1970-01-01 to a civil date (proleptic Gregorian calendar).
//
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const adjustedYear = if (month <= 2) year - 1 else year;
    const era = @divFloor(adjustedYear, 400);
    const yearOfEra = adjustedYear - era * 400;
    const monthIndex = if (month > 2) month - 3 else month + 9;
    const dayOfYear = @divFloor(153 * monthIndex + 2, 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100) + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

//
// Parses an HTTP date such as "Wed, 12 Oct 2009 17:50:00 GMT" into milliseconds since the Unix epoch.
//
pub fn parseHttpDate(text: []const u8) ?i64 {
    var parts = std.mem.tokenizeAny(u8, text, " ,:");
    _ = parts.next() orelse {
        return null;
    };
    const dayText = parts.next() orelse {
        return null;
    };
    const monthText = parts.next() orelse {
        return null;
    };
    const yearText = parts.next() orelse {
        return null;
    };
    const hourText = parts.next() orelse {
        return null;
    };
    const minuteText = parts.next() orelse {
        return null;
    };
    const secondText = parts.next() orelse {
        return null;
    };
    var month: i64 = 0;
    for (month_names, 0..) |monthName, index| {
        if (std.ascii.eqlIgnoreCase(monthName, monthText)) {
            month = @intCast(index + 1);
        }
    }
    if (month == 0) {
        return null;
    }
    const day = std.fmt.parseInt(i64, dayText, 10) catch {
        return null;
    };
    const year = std.fmt.parseInt(i64, yearText, 10) catch {
        return null;
    };
    const hour = std.fmt.parseInt(i64, hourText, 10) catch {
        return null;
    };
    const minute = std.fmt.parseInt(i64, minuteText, 10) catch {
        return null;
    };
    const second = std.fmt.parseInt(i64, secondText, 10) catch {
        return null;
    };
    const days = daysFromCivil(year, month, day);
    return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000;
}

//
// Input of ListObjectsV2.
//
pub const ListObjectsV2Input = struct {
    // The bucket.
    Bucket: []const u8,

    // Limits the response to keys that begin with the prefix.
    Prefix: []const u8,

    // Groups keys that contain the delimiter after the prefix into CommonPrefixes (null for none).
    Delimiter: ?[]const u8,

    // The maximum number of keys returned (null for the S3 default of 1000).
    MaxKeys: ?u32,

    // The continuation token from the previous page (null for the first page).
    ContinuationToken: ?[]const u8,
};

//
// An object in a ListObjectsV2 result.
//
pub const S3Object = struct {
    // The object key.
    Key: []const u8,
};

//
// A common prefix in a ListObjectsV2 result.
//
pub const CommonPrefix = struct {
    // The prefix (ends with the delimiter).
    Prefix: []const u8,
};

//
// Output of ListObjectsV2 (null fields are absent from the response, like the SDK's undefined).
//
pub const ListObjectsV2Output = struct {
    // The objects.
    Contents: ?[]const S3Object,

    // The common prefixes (the "directories").
    CommonPrefixes: ?[]const CommonPrefix,

    // The token for the next page.
    NextContinuationToken: ?[]const u8,

    // True when there are more results.
    IsTruncated: bool,
};

//
// Output of HeadObject.
//
pub const HeadObjectOutput = struct {
    // The content type.
    ContentType: ?[]const u8,

    // The length of the object.
    ContentLength: u64,

    // The last modified time in milliseconds since the Unix epoch (null when absent).
    LastModified: ?i64,
};

//
// Output of GetObject.
//
pub const GetObjectOutput = struct {
    // The body (the SDK's Body.transformToByteArray()). Null when the response has no content, so the
    // `if (!response.Body)` checks of the callers see a response without a body.
    Body: ?[]u8,

    // The Content-Range header of a range request.
    ContentRange: ?[]const u8,
};

//
// A completed part of a multipart upload.
//
pub const CompletedPart = struct {
    // The part number (starting at 1).
    PartNumber: u32,

    // The ETag returned by UploadPart.
    ETag: []const u8,
};

//
// The client: signs and sends S3 requests.
//
pub const S3Client = struct {
    // The HTTP client (its connection pool is shared by all threads; it allocates with the thread-safe smp allocator).
    httpClient: std.http.Client,

    // The client configuration.
    config: IS3ClientConfig,

    //
    // Creates a client (TypeScript: `new S3Client(config)`).
    //
    pub fn init(io: std.Io, config: IS3ClientConfig) S3Client {
        return .{
            .httpClient = .{ .allocator = std.heap.smp_allocator, .io = io },
            .config = config,
        };
    }

    //
    // Closes the pooled connections.
    //
    pub fn deinit(self: *S3Client) void {
        self.httpClient.deinit();
    }

    //
    // Gets the credentials: from the configuration or from the environment (the SDK's default provider chain).
    //
    fn resolveCredentials(self: *S3Client) !sigv4.ICredentials {
        if (self.config.credentials) |credentials| {
            return credentials;
        }
        const accessKeyId = node_utils.process_env.getEnv("AWS_ACCESS_KEY_ID");
        const secretAccessKey = node_utils.process_env.getEnv("AWS_SECRET_ACCESS_KEY");
        if (accessKeyId != null and secretAccessKey != null) {
            return .{
                .accessKeyId = accessKeyId.?,
                .secretAccessKey = secretAccessKey.?,
                .sessionToken = node_utils.process_env.getEnv("AWS_SESSION_TOKEN"),
            };
        }
        last_http_status_code = 0;
        errors.recordError("CredentialsProviderError", "Could not load credentials from any providers", .{});
        return error.Thrown;
    }

    //
    // Gets the region: from the configuration or from the AWS_REGION environment variable.
    //
    fn resolveRegion(self: *S3Client) ![]const u8 {
        if (self.config.region) |region| {
            if (region.len > 0) {
                return region;
            }
        }
        if (node_utils.process_env.getEnv("AWS_REGION")) |region| {
            return region;
        }
        last_http_status_code = 0;
        return errors.throwError("Region is missing", .{});
    }

    //
    // Signs and sends a request and returns the response whatever its status.
    //
    pub fn execute(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, request: S3Request) !S3Response {
        const credentials = try self.resolveCredentials();
        const region = try self.resolveRegion();
        const endpoint = try resolveEndpoint(allocator, self.config.endpoint, region);
        const location = try resolveRequestLocation(allocator, endpoint, request.bucket, request.key);

        const body = request.body orelse "";
        const payloadHash = sigv4.sha256Hex(body);
        const amzDate = sigv4.formatAmzDate(std.Io.Clock.real.now(io).toMilliseconds());

        var headers: std.ArrayList(sigv4.IHeader) = .empty;
        try headers.append(allocator, .{ .name = "host", .value = location.host });
        try headers.append(allocator, .{ .name = "x-amz-content-sha256", .value = try allocator.dupe(u8, &payloadHash) });
        try headers.append(allocator, .{ .name = "x-amz-date", .value = try allocator.dupe(u8, &amzDate) });
        if (credentials.sessionToken) |sessionToken| {
            try headers.append(allocator, .{ .name = "x-amz-security-token", .value = sessionToken });
        }
        try headers.appendSlice(allocator, request.headers);

        const signature = try sigv4.sign(allocator, credentials, .{
            .method = @tagName(request.method),
            .canonicalUri = location.path,
            .query = request.query,
            .headers = headers.items,
            .payloadHash = &payloadHash,
            .region = region,
            .service = "s3",
            .amzDate = &amzDate,
        });

        var extraHeaders: std.ArrayList(std.http.Header) = .empty;
        for (headers.items[1..]) |header| {
            try extraHeaders.append(allocator, .{ .name = header.name, .value = header.value });
        }
        try extraHeaders.append(allocator, .{ .name = "authorization", .value = signature.authorization });

        const queryString = try sigv4.canonicalQueryString(allocator, request.query);
        const uri: std.Uri = .{
            .scheme = endpoint.scheme,
            .host = .{ .raw = location.hostname },
            .port = endpoint.port,
            .path = .{ .percent_encoded = location.path },
            .query = if (queryString.len > 0) .{ .percent_encoded = queryString } else null,
        };

        var httpRequest = try self.httpClient.request(request.method, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = true,
            .headers = .{
                .host = .{ .override = location.host },
                .accept_encoding = .omit,
                .authorization = .omit,
            },
            .extra_headers = extraHeaders.items,
        });
        defer httpRequest.deinit();

        if (request.method.requestHasBody()) {
            httpRequest.transfer_encoding = .{ .content_length = body.len };
            var bodyWriter = try httpRequest.sendBodyUnflushed(&.{});
            try bodyWriter.writer.writeAll(body);
            try bodyWriter.end();
            try httpRequest.connection.?.flush();
        }
        else {
            try httpRequest.sendBodiless();
        }

        var response = try httpRequest.receiveHead(&.{});
        var responseHeaders: std.ArrayList(sigv4.IHeader) = .empty;
        var headerIterator = response.head.iterateHeaders();
        while (headerIterator.next()) |header| {
            try responseHeaders.append(allocator, .{
                .name = try allocator.dupe(u8, header.name),
                .value = try allocator.dupe(u8, header.value),
            });
        }
        const status: u16 = @intFromEnum(response.head.status);

        const bodyReader = response.reader(&.{});
        const responseBody = bodyReader.allocRemaining(allocator, .unlimited) catch |err| {
            if (err == error.ReadFailed) {
                return response.bodyErr() orelse err;
            }
            return err;
        };
        return .{
            .status = status,
            .headers = try responseHeaders.toOwnedSlice(allocator),
            .body = responseBody,
        };
    }

    //
    // Sends a request and throws the S3 error when the response is not successful (TypeScript: `s3.send(command)`).
    //
    pub fn send(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, request: S3Request) !S3Response {
        const response = try self.execute(allocator, io, request);
        if (response.status >= 200 and response.status < 300) {
            return response;
        }
        return throwResponseError(allocator, response);
    }

    //
    // ListObjectsV2.
    //
    pub fn listObjectsV2(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, input: ListObjectsV2Input) !ListObjectsV2Output {
        var query: std.ArrayList(sigv4.IQueryParameter) = .empty;
        try query.append(allocator, .{ .name = "list-type", .value = "2" });
        try query.append(allocator, .{ .name = "prefix", .value = input.Prefix });
        if (input.Delimiter) |delimiter| {
            try query.append(allocator, .{ .name = "delimiter", .value = delimiter });
        }
        if (input.MaxKeys) |maxKeys| {
            try query.append(allocator, .{ .name = "max-keys", .value = try std.fmt.allocPrint(allocator, "{d}", .{maxKeys}) });
        }
        if (input.ContinuationToken) |continuationToken| {
            try query.append(allocator, .{ .name = "continuation-token", .value = continuationToken });
        }
        const response = try self.send(allocator, io, .{
            .method = .GET,
            .bucket = input.Bucket,
            .key = null,
            .query = query.items,
            .headers = &.{},
            .body = null,
        });

        var contents: ?[]const S3Object = null;
        const contentElements = try xmlElements(allocator, response.body, "Contents");
        if (contentElements.len > 0) {
            const objects = try allocator.alloc(S3Object, contentElements.len);
            for (contentElements, 0..) |element, index| {
                objects[index] = .{ .Key = (try xmlText(allocator, element, "Key")) orelse "" };
            }
            contents = objects;
        }

        var commonPrefixes: ?[]const CommonPrefix = null;
        const prefixElements = try xmlElements(allocator, response.body, "CommonPrefixes");
        if (prefixElements.len > 0) {
            const prefixes = try allocator.alloc(CommonPrefix, prefixElements.len);
            for (prefixElements, 0..) |element, index| {
                prefixes[index] = .{ .Prefix = (try xmlText(allocator, element, "Prefix")) orelse "" };
            }
            commonPrefixes = prefixes;
        }

        const isTruncated = (try xmlText(allocator, response.body, "IsTruncated")) orelse "false";
        return .{
            .Contents = contents,
            .CommonPrefixes = commonPrefixes,
            .NextContinuationToken = try xmlText(allocator, response.body, "NextContinuationToken"),
            .IsTruncated = std.mem.eql(u8, isTruncated, "true"),
        };
    }

    //
    // HeadObject.
    //
    pub fn headObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8) !HeadObjectOutput {
        const response = try self.send(allocator, io, .{
            .method = .HEAD,
            .bucket = bucket,
            .key = key,
            .query = &.{},
            .headers = &.{},
            .body = null,
        });
        var contentLength: u64 = 0;
        if (response.header("content-length")) |lengthText| {
            contentLength = std.fmt.parseInt(u64, lengthText, 10) catch 0;
        }
        var lastModified: ?i64 = null;
        if (response.header("last-modified")) |dateText| {
            lastModified = parseHttpDate(dateText);
        }
        return .{
            .ContentType = response.header("content-type"),
            .ContentLength = contentLength,
            .LastModified = lastModified,
        };
    }

    //
    // GetObject, optionally for a byte range such as "bytes=0-99".
    //
    pub fn getObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, range: ?[]const u8) !GetObjectOutput {
        var headers: std.ArrayList(sigv4.IHeader) = .empty;
        if (range) |rangeValue| {
            try headers.append(allocator, .{ .name = "range", .value = rangeValue });
        }
        const response = try self.send(allocator, io, .{
            .method = .GET,
            .bucket = bucket,
            .key = key,
            .query = &.{},
            .headers = headers.items,
            .body = null,
        });
        return .{
            .Body = if (response.body.len == 0) null else response.body,
            .ContentRange = response.header("content-range"),
        };
    }

    //
    // PutObject.
    //
    pub fn putObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, body: []const u8, contentType: ?[]const u8) !void {
        var headers: std.ArrayList(sigv4.IHeader) = .empty;
        if (contentType) |contentTypeValue| {
            try headers.append(allocator, .{ .name = "content-type", .value = contentTypeValue });
        }
        _ = try self.send(allocator, io, .{
            .method = .PUT,
            .bucket = bucket,
            .key = key,
            .query = &.{},
            .headers = headers.items,
            .body = body,
        });
    }

    //
    // DeleteObject.
    //
    pub fn deleteObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8) !void {
        _ = try self.send(allocator, io, .{
            .method = .DELETE,
            .bucket = bucket,
            .key = key,
            .query = &.{},
            .headers = &.{},
            .body = null,
        });
    }

    //
    // DeleteObjects (up to 1000 keys).
    //
    pub fn deleteObjects(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, keys: []const []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
        for (keys) |key| {
            try body.print(allocator, "<Object><Key>{s}</Key></Object>", .{try xmlEncode(allocator, key)});
        }
        try body.appendSlice(allocator, "</Delete>");
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        std.crypto.hash.Md5.hash(body.items, &digest, .{});
        var md5Base64: [24]u8 = undefined;
        const md5Text = std.base64.standard.Encoder.encode(&md5Base64, &digest);
        const headers = [_]sigv4.IHeader{
            .{ .name = "content-md5", .value = md5Text },
            .{ .name = "content-type", .value = "application/xml" },
        };
        _ = try self.send(allocator, io, .{
            .method = .POST,
            .bucket = bucket,
            .key = null,
            .query = &.{.{ .name = "delete", .value = "" }},
            .headers = &headers,
            .body = body.items,
        });
    }

    //
    // CopyObject (copySource is "<bucket>/<key>").
    //
    pub fn copyObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, copySource: []const u8, key: []const u8) !void {
        const headers = [_]sigv4.IHeader{
            .{ .name = "x-amz-copy-source", .value = try sigv4.uriEncode(allocator, copySource, false) },
        };
        const response = try self.send(allocator, io, .{
            .method = .PUT,
            .bucket = bucket,
            .key = key,
            .query = &.{},
            .headers = &headers,
            .body = "",
        });
        // CopyObject can report an error in a 200 response.
        if (std.mem.indexOf(u8, response.body, "<Error>") != null) {
            return throwResponseError(allocator, .{ .status = 500, .headers = response.headers, .body = response.body });
        }
    }

    //
    // CreateMultipartUpload: returns the upload id.
    //
    pub fn createMultipartUpload(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, contentType: ?[]const u8) ![]const u8 {
        var headers: std.ArrayList(sigv4.IHeader) = .empty;
        if (contentType) |contentTypeValue| {
            try headers.append(allocator, .{ .name = "content-type", .value = contentTypeValue });
        }
        const response = try self.send(allocator, io, .{
            .method = .POST,
            .bucket = bucket,
            .key = key,
            .query = &.{.{ .name = "uploads", .value = "" }},
            .headers = headers.items,
            .body = "",
        });
        return (try xmlText(allocator, response.body, "UploadId")) orelse {
            return errors.throwError("CreateMultipartUpload did not return an UploadId", .{});
        };
    }

    //
    // UploadPart: returns the ETag of the part.
    //
    pub fn uploadPart(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, uploadId: []const u8, partNumber: u32, body: []const u8) ![]const u8 {
        const query = [_]sigv4.IQueryParameter{
            .{ .name = "partNumber", .value = try std.fmt.allocPrint(allocator, "{d}", .{partNumber}) },
            .{ .name = "uploadId", .value = uploadId },
        };
        const response = try self.send(allocator, io, .{
            .method = .PUT,
            .bucket = bucket,
            .key = key,
            .query = &query,
            .headers = &.{},
            .body = body,
        });
        return response.header("etag") orelse "";
    }

    //
    // CompleteMultipartUpload.
    //
    pub fn completeMultipartUpload(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, uploadId: []const u8, parts: []const CompletedPart) !void {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
        for (parts) |part| {
            try body.print(allocator, "<Part><ETag>{s}</ETag><PartNumber>{d}</PartNumber></Part>", .{ try xmlEncode(allocator, part.ETag), part.PartNumber });
        }
        try body.appendSlice(allocator, "</CompleteMultipartUpload>");
        const headers = [_]sigv4.IHeader{
            .{ .name = "content-type", .value = "application/xml" },
        };
        const response = try self.send(allocator, io, .{
            .method = .POST,
            .bucket = bucket,
            .key = key,
            .query = &.{.{ .name = "uploadId", .value = uploadId }},
            .headers = &headers,
            .body = body.items,
        });
        // CompleteMultipartUpload can report an error in a 200 response.
        if (std.mem.indexOf(u8, response.body, "<Error>") != null) {
            return throwResponseError(allocator, .{ .status = 500, .headers = response.headers, .body = response.body });
        }
    }

    //
    // AbortMultipartUpload.
    //
    pub fn abortMultipartUpload(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, uploadId: []const u8) !void {
        _ = try self.send(allocator, io, .{
            .method = .DELETE,
            .bucket = bucket,
            .key = key,
            .query = &.{.{ .name = "uploadId", .value = uploadId }},
            .headers = &.{},
            .body = null,
        });
    }
};

//
// Throws the error described by an unsuccessful response (the SDK's service exception: name = Code, message = Message).
//
fn throwResponseError(allocator: std.mem.Allocator, response: S3Response) anyerror {
    last_http_status_code = response.status;
    const code = try xmlText(allocator, response.body, "Code");
    const message = try xmlText(allocator, response.body, "Message");
    if (code) |codeText| {
        errors.recordError(staticErrorName(codeText), "{s}", .{message orelse codeText});
    }
    else {
        const name = errorNameForStatus(response.status);
        errors.recordError(name, "{s}", .{name});
    }
    return error.Thrown;
}

//
// The body of an Upload.
//
pub const UploadBody = union(enum) {
    // A buffer in memory.
    buffer: []const u8,

    // A stream.
    stream: *std.Io.Reader,
};

//
// The params of an Upload (the PutObject input).
//
pub const IUploadParams = struct {
    // The bucket.
    Bucket: []const u8,

    // The object key.
    Key: []const u8,

    // The data to upload.
    Body: UploadBody,

    // The content type (null for none).
    ContentType: ?[]const u8,

    // The length of the body when known.
    ContentLength: ?u64,
};

//
// The options of an Upload.
//
pub const IUploadOptions = struct {
    // The client.
    client: *S3Client,

    // What to upload.
    params: IUploadParams,

    // The size of each part of a multipart upload.
    partSize: u64,

    // The number of parts uploaded concurrently (only 1 is supported, which is what CloudStorage uses).
    queueSize: u32,
};

//
// Uploads a buffer or a stream, with a single PutObject when it fits in one part and with a multipart upload otherwise
// (TypeScript: `new Upload({ client, params, partSize, queueSize }).done()` from @aws-sdk/lib-storage).
// Part buffers are allocated with the page allocator and freed after each part, so large uploads do not grow the
// caller's arena.
//
pub const Upload = struct {
    // The upload options.
    options: IUploadOptions,

    //
    // Creates the upload.
    //
    pub fn init(options: IUploadOptions) Upload {
        return .{ .options = options };
    }

    //
    // Reads the next part from the body into a new buffer; the returned slice is shorter than partSize at the end.
    //
    fn readPart(self: *Upload, offset: *usize) ![]const u8 {
        const partSize: usize = @intCast(self.options.partSize);
        switch (self.options.params.Body) {
            .buffer => |buffer| {
                const end = @min(buffer.len, offset.* + partSize);
                const part = buffer[offset.*..end];
                offset.* = end;
                return part;
            },
            .stream => |stream| {
                var part: std.ArrayList(u8) = .empty;
                errdefer part.deinit(std.heap.page_allocator);
                var chunk: [64 * 1024]u8 = undefined;
                while (part.items.len < partSize) {
                    const wanted = @min(chunk.len, partSize - part.items.len);
                    const count = try stream.readSliceShort(chunk[0..wanted]);
                    if (count == 0) {
                        break;
                    }
                    try part.appendSlice(std.heap.page_allocator, chunk[0..count]);
                }
                offset.* += part.items.len;
                return part.toOwnedSlice(std.heap.page_allocator);
            },
        }
    }

    //
    // Frees a part returned by readPart.
    //
    fn freePart(self: *Upload, part: []const u8) void {
        if (self.options.params.Body == .stream) {
            std.heap.page_allocator.free(part);
        }
    }

    //
    // Runs the upload.
    //
    pub fn done(self: *Upload, allocator: std.mem.Allocator, io: std.Io) !void {
        const client = self.options.client;
        const params = self.options.params;
        var offset: usize = 0;
        const firstPart = try self.readPart(&offset);
        defer self.freePart(firstPart);
        if (firstPart.len < self.options.partSize) {
            try client.putObject(allocator, io, params.Bucket, params.Key, firstPart, params.ContentType);
            return;
        }

        // A second part decides between a single PutObject and a multipart upload.
        const secondPart = try self.readPart(&offset);
        if (secondPart.len == 0) {
            self.freePart(secondPart);
            try client.putObject(allocator, io, params.Bucket, params.Key, firstPart, params.ContentType);
            return;
        }

        const uploadId = try client.createMultipartUpload(allocator, io, params.Bucket, params.Key, params.ContentType);
        var parts: std.ArrayList(CompletedPart) = .empty;
        self.uploadParts(allocator, io, uploadId, firstPart, secondPart, &offset, &parts) catch |err| {
            var errorRecord: errors.ErrorRecord = undefined;
            errors.captureError(&errorRecord);
            client.abortMultipartUpload(allocator, io, params.Bucket, params.Key, uploadId) catch {};
            errors.restoreError(&errorRecord);
            return err;
        };
        try client.completeMultipartUpload(allocator, io, params.Bucket, params.Key, uploadId, parts.items);
    }

    //
    // Uploads the parts of a multipart upload, starting with the two parts already read.
    //
    fn uploadParts(self: *Upload, allocator: std.mem.Allocator, io: std.Io, uploadId: []const u8, firstPart: []const u8, secondPart: []const u8, offset: *usize, parts: *std.ArrayList(CompletedPart)) !void {
        const client = self.options.client;
        const params = self.options.params;
        const firstETag = try client.uploadPart(allocator, io, params.Bucket, params.Key, uploadId, 1, firstPart);
        try parts.append(allocator, .{ .PartNumber = 1, .ETag = firstETag });

        var part = secondPart;
        var partNumber: u32 = 2;
        while (part.len > 0) {
            const currentPart = part;
            defer self.freePart(currentPart);
            const etag = try client.uploadPart(allocator, io, params.Bucket, params.Key, uploadId, partNumber, currentPart);
            try parts.append(allocator, .{ .PartNumber = partNumber, .ETag = etag });
            partNumber += 1;
            if (currentPart.len < self.options.partSize) {
                break;
            }
            part = try self.readPart(offset);
        }
    }
};
