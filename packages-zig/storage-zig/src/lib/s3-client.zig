const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const aws = @import("aws-c");

//
// A thin binding to the AWS SDK for C (aws-c-s3 and the libraries under it). No TypeScript counterpart: it stands in
// for the parts of `@aws-sdk/client-s3` (S3Client and the commands CloudStorage sends) and `@aws-sdk/lib-storage`
// (Upload) that CloudStorage uses. The SDK resolves the endpoint (the S3 endpoint rules), signs (SigV4), sends,
// uploads in parts, computes the Content-MD5 and parses XML; this file builds the command messages (the path, query
// string and headers the JavaScript SDK serializes each command to) and maps the results. Command inputs
// and outputs keep the JavaScript SDK's PascalCase field names so CloudStorage reads like the TypeScript. Errors
// returned by S3 are thrown with the S3 error code as the error name (utils errors.lastErrorName(), the SDK's
// `err.name`) and the HTTP status in lastHttpStatusCode() (the SDK's `err.$metadata.httpStatusCode`).
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
// Gets the type a function returns a pointer to: the SDK's handle types (struct aws_s3_client, struct
// aws_s3_meta_request), whose translated names translate-c gives a numeric suffix.
//
fn ReturnedPointee(comptime function: anytype) type {
    const returnType = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    return @typeInfo(@typeInfo(returnType).optional.child).pointer.child;
}

//
// struct aws_s3_client.
//
const S3ClientHandle = ReturnedPointee(aws.aws_s3_client_new);

//
// struct aws_s3_meta_request.
//
const MetaRequestHandle = ReturnedPointee(aws.aws_s3_client_make_meta_request);

//
// The one-bit flags of struct aws_signing_config_aws (`uint32_t name : 1` bit-fields, which C packs into one uint32_t
// from the lowest bit).
//
pub const SigningConfigFlags = packed struct(u32) {
    // Double URI-encode the path when signing.
    use_double_uri_encode: u1,

    // Normalize the path when signing.
    should_normalize_uri_path: u1,

    // Leave the session token out of the signature.
    omit_session_token: u1,

    // The rest of the uint32_t.
    unused: u29,
};

//
// struct aws_signing_config_aws from aws/auth/signing_config.h, which translate-c leaves opaque because of its `flags`
// bit-field: the same fields in the same order, so a pointer to it is a pointer to the SDK's struct.
//
pub const SigningConfigAws = extern struct {
    // AWS_SIGNING_CONFIG_AWS.
    config_type: aws.enum_aws_signing_config_type,

    // The signing algorithm.
    algorithm: aws.enum_aws_signing_algorithm,

    // What is signed (for example the request headers).
    signature_type: aws.enum_aws_signature_type,

    // The region to sign for.
    region: aws.aws_byte_cursor,

    // The service to sign for.
    service: aws.aws_byte_cursor,

    // The signing time.
    date: aws.struct_aws_date_time,

    // Decides which headers are signed (null for all).
    should_sign_header: ?*const aws.aws_should_sign_header_fn,

    // The user data of should_sign_header.
    should_sign_header_ud: ?*anyopaque,

    // The bit-field flags.
    flags: SigningConfigFlags,

    // The payload hash to sign with (empty to hash the body).
    signed_body_value: aws.aws_byte_cursor,

    // The header the payload hash is sent in.
    signed_body_header: aws.enum_aws_signed_body_header_type,

    // Credentials to sign with (null to use credentials_provider).
    credentials: ?*const aws.struct_aws_credentials,

    // Provides the credentials.
    credentials_provider: ?*aws.struct_aws_credentials_provider,

    // How long a presigned request is valid.
    expiration_in_seconds: u64,

    //
    // Gets the SDK's view of the config.
    //
    pub fn sdk(self: *const SigningConfigAws) *const aws.struct_aws_signing_config_aws {
        return @ptrCast(self);
    }
};

//
// Guards library_initialized. (aws_thread_call_once is not used: its AWS_THREAD_ONCE_STATIC_INIT is a braced
// initializer on Windows, which translate-c cannot translate.)
//
var library_mutex: std.Io.Mutex = .init;

//
// True once aws_s3_library_init has run.
//
var library_initialized: bool = false;

//
// Initializes the AWS SDK for C (aws-c-s3 and every library it depends on) the first time it is called.
//
fn initLibrary(io: std.Io) void {
    library_mutex.lockUncancelable(io);
    defer library_mutex.unlock(io);
    if (!library_initialized) {
        aws.aws_s3_library_init(aws.aws_default_allocator());
        library_initialized = true;
    }
}

//
// Makes a byte cursor (the SDK's string view) over a slice.
//
pub fn cursorOf(bytes: []const u8) aws.aws_byte_cursor {
    return .{
        .len = bytes.len,
        .ptr = @constCast(bytes.ptr),
    };
}

//
// Gets the bytes of a byte cursor.
//
pub fn sliceOf(cursor: aws.aws_byte_cursor) []const u8 {
    if (cursor.len == 0) {
        return "";
    }
    return cursor.ptr[0..cursor.len];
}

//
// Credentials (the SDK's AwsCredentialIdentity).
//
pub const ICredentials = struct {
    // The access key id.
    accessKeyId: []const u8,

    // The secret access key.
    secretAccessKey: []const u8,

    // The session token (null for none).
    sessionToken: ?[]const u8,
};

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
    credentials: ?ICredentials,
};

//
// A response header.
//
pub const IHeader = struct {
    // The header name.
    name: []const u8,

    // The header value.
    value: []const u8,
};

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
pub fn staticErrorName(code: []const u8) []const u8 {
    for (known_error_names) |name| {
        if (std.mem.eql(u8, name, code)) {
            return name;
        }
    }
    return "S3ServiceException";
}

//
// The error name the JavaScript SDK uses for an error response without a body (for example a HEAD request).
//
pub fn errorNameForStatus(status: u16) []const u8 {
    return switch (status) {
        400 => "BadRequest",
        403 => "Forbidden",
        404 => "NotFound",
        412 => "PreconditionFailed",
        else => "UnknownError",
    };
}

//
// Throws the error of the SDK's most recent failed call on this thread (aws_last_error), named after the SDK's
// error code.
//
fn throwLastSdkError() anyerror {
    return throwSdkError(aws.aws_last_error());
}

//
// Throws an error of the SDK that did not come from an S3 response, named after the SDK's error code.
//
fn throwSdkError(errorCode: c_int) anyerror {
    last_http_status_code = 0;
    errors.recordError(std.mem.span(aws.aws_error_name(errorCode)), "{s}", .{std.mem.span(aws.aws_error_str(errorCode))});
    return error.Thrown;
}

//
// Gets the text of the <Error><name> element of an S3 error response with its XML escapes removed (null when there
// is none), using the SDK's XML parser.
//
fn errorElementText(allocator: std.mem.Allocator, body: []const u8, name: [*:0]const u8) !?[]const u8 {
    var path = [_:null]?[*:0]const u8{ "Error", name };
    var text: aws.aws_byte_cursor = undefined;
    if (aws.aws_xml_get_body_at_path(aws.aws_default_allocator(), cursorOf(body), @ptrCast(&path), &text) != aws.AWS_OP_SUCCESS) {
        return null;
    }
    return try unescapeXml(allocator, text);
}

//
// Removes the XML escapes of text with the SDK's aws_byte_buf_append_unescaped_xml.
//
fn unescapeXml(allocator: std.mem.Allocator, text: aws.aws_byte_cursor) ![]const u8 {
    var buffer: aws.aws_byte_buf = undefined;
    if (aws.aws_byte_buf_init(&buffer, aws.aws_default_allocator(), text.len) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    defer aws.aws_byte_buf_clean_up(&buffer);
    if (aws.aws_byte_buf_append_unescaped_xml(aws.aws_default_allocator(), text, &buffer) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    return allocator.dupe(u8, sliceOf(aws.aws_byte_cursor_from_buf(&buffer)));
}

//
// Throws the error of a failed meta request: the S3 service exception of an S3 error response (name = Code,
// message = Message, like the SDK), or the SDK's own error when there was no S3 response.
//
fn throwResultError(allocator: std.mem.Allocator, result: *const MetaRequestCall) anyerror {
    if (result.responseStatus == 0) {
        return throwSdkError(result.errorCode);
    }
    last_http_status_code = @intCast(result.responseStatus);
    if (result.errorBody) |body| {
        if (try errorElementText(allocator, body, "Code")) |code| {
            const message = (try errorElementText(allocator, body, "Message")) orelse code;
            errors.recordError(staticErrorName(code), "{s}", .{message});
            return error.Thrown;
        }
    }
    const name = errorNameForStatus(last_http_status_code);
    errors.recordError(name, "{s}", .{name});
    return error.Thrown;
}

//
// One meta request (one S3 operation run by aws-c-s3) and what its callbacks received. The callbacks run on the
// SDK's threads while the calling thread waits for them, so every field is guarded by `mutex`.
//
const MetaRequestCall = struct {
    // Guards the fields below.
    mutex: aws.aws_mutex,

    // Signalled whenever a callback changed the fields below.
    signal: aws.aws_condition_variable,

    // Allocates the response copied out of the callbacks (the caller's allocator; the caller waits, so only one
    // thread uses it at a time).
    allocator: std.mem.Allocator,

    // The response headers (from the headers callback).
    headers: std.ArrayList(IHeader),

    // The response body (from the body callback).
    body: std.ArrayList(u8),

    // True when an allocation in a callback failed.
    outOfMemory: bool,

    // True once the finish callback ran.
    finished: bool,

    // True once the shutdown callback ran (the SDK no longer uses anything the call lent it).
    shutDown: bool,

    // True once the waker of a pending aws_s3_meta_request_poll_write ran.
    writable: bool,

    // The error code of the meta request (0 for success).
    errorCode: c_int,

    // The HTTP status of the response (of the failed request when the meta request failed; 0 for none).
    responseStatus: c_int,

    // The body of the S3 error response (null for none).
    errorBody: ?[]const u8,

    //
    // Prepares a call.
    //
    fn init(self: *MetaRequestCall, allocator: std.mem.Allocator) void {
        self.* = .{
            .mutex = undefined,
            .signal = undefined,
            .allocator = allocator,
            .headers = .empty,
            .body = .empty,
            .outOfMemory = false,
            .finished = false,
            .shutDown = false,
            .writable = false,
            .errorCode = 0,
            .responseStatus = 0,
            .errorBody = null,
        };
        _ = aws.aws_mutex_init(&self.mutex);
        _ = aws.aws_condition_variable_init(&self.signal);
    }

    //
    // Frees the synchronization objects.
    //
    fn deinit(self: *MetaRequestCall) void {
        aws.aws_condition_variable_clean_up(&self.signal);
        aws.aws_mutex_clean_up(&self.mutex);
    }

    //
    // Gets the call from the user data of a callback.
    //
    fn fromUserData(user_data: ?*anyopaque) *MetaRequestCall {
        return @ptrCast(@alignCast(user_data.?));
    }

    //
    // Sets a flag under the mutex and wakes the waiting thread.
    //
    fn raise(self: *MetaRequestCall, flag: *bool) void {
        _ = aws.aws_mutex_lock(&self.mutex);
        flag.* = true;
        _ = aws.aws_condition_variable_notify_all(&self.signal);
        _ = aws.aws_mutex_unlock(&self.mutex);
    }

    //
    // Waits until a flag is set, then clears it when asked to.
    //
    fn wait(self: *MetaRequestCall, flag: *bool, clear: bool) void {
        _ = aws.aws_mutex_lock(&self.mutex);
        while (!flag.*) {
            _ = aws.aws_condition_variable_wait(&self.signal, &self.mutex);
        }
        if (clear) {
            flag.* = false;
        }
        _ = aws.aws_mutex_unlock(&self.mutex);
    }

    //
    // Gets a response header by name (case-insensitive).
    //
    fn header(self: *const MetaRequestCall, name: []const u8) ?[]const u8 {
        for (self.headers.items) |responseHeader| {
            if (std.ascii.eqlIgnoreCase(responseHeader.name, name)) {
                return responseHeader.value;
            }
        }
        return null;
    }

    //
    // The headers callback: copies the response headers.
    //
    fn onHeaders(meta_request: ?*MetaRequestHandle, headers: ?*const aws.aws_http_headers, response_status: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = meta_request;
        const self = fromUserData(user_data);
        _ = aws.aws_mutex_lock(&self.mutex);
        defer _ = aws.aws_mutex_unlock(&self.mutex);
        self.responseStatus = response_status;
        const count = aws.aws_http_headers_count(headers);
        var index: usize = 0;
        while (index < count) {
            var responseHeader: aws.aws_http_header = undefined;
            if (aws.aws_http_headers_get_index(headers, index, &responseHeader) == aws.AWS_OP_SUCCESS) {
                self.appendHeader(responseHeader) catch {
                    self.outOfMemory = true;
                };
            }
            index += 1;
        }
        return aws.AWS_OP_SUCCESS;
    }

    //
    // Copies one response header.
    //
    fn appendHeader(self: *MetaRequestCall, responseHeader: aws.aws_http_header) !void {
        try self.headers.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, sliceOf(responseHeader.name)),
            .value = try self.allocator.dupe(u8, sliceOf(responseHeader.value)),
        });
    }

    //
    // The body callback: appends the received bytes (the SDK delivers them in order).
    //
    fn onBody(meta_request: ?*MetaRequestHandle, body: [*c]const aws.aws_byte_cursor, range_start: u64, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = meta_request;
        _ = range_start;
        const self = fromUserData(user_data);
        _ = aws.aws_mutex_lock(&self.mutex);
        defer _ = aws.aws_mutex_unlock(&self.mutex);
        self.body.appendSlice(self.allocator, sliceOf(body.*)) catch {
            self.outOfMemory = true;
            return aws.aws_raise_error(aws.AWS_ERROR_OOM);
        };
        return aws.AWS_OP_SUCCESS;
    }

    //
    // The finish callback: records the result.
    //
    fn onFinish(meta_request: ?*MetaRequestHandle, result: [*c]const aws.aws_s3_meta_request_result, user_data: ?*anyopaque) callconv(.c) void {
        _ = meta_request;
        const self = fromUserData(user_data);
        _ = aws.aws_mutex_lock(&self.mutex);
        self.errorCode = result.*.error_code;
        if (result.*.error_code != 0 or self.responseStatus == 0) {
            self.responseStatus = result.*.response_status;
        }
        if (result.*.error_response_body != null) {
            const errorBody = result.*.error_response_body.*;
            self.errorBody = self.allocator.dupe(u8, sliceOf(aws.aws_byte_cursor_from_buf(&errorBody))) catch blk: {
                self.outOfMemory = true;
                break :blk null;
            };
        }
        self.finished = true;
        _ = aws.aws_condition_variable_notify_all(&self.signal);
        _ = aws.aws_mutex_unlock(&self.mutex);
    }

    //
    // The shutdown callback: the SDK is done with the meta request.
    //
    fn onShutdown(user_data: ?*anyopaque) callconv(.c) void {
        const self = fromUserData(user_data);
        self.raise(&self.shutDown);
    }

    //
    // The waker of a pending aws_s3_meta_request_poll_write.
    //
    fn onWritable(user_data: ?*anyopaque) callconv(.c) void {
        const self = fromUserData(user_data);
        self.raise(&self.writable);
    }
};

//
// The retry strategy of the client: one attempt per request and no retries, the `maxAttempts: 1` of
// CloudStorage.buildClient. It is aws-c-io's retry strategy interface (aws_retry_strategy_vtable) with retries
// refused. aws-c-io's own aws_retry_strategy_new_no_retry cannot be used with aws-c-s3: aws-c-s3 acquires a retry token
// before the first attempt of every request, and that strategy refuses to hand one out, which fails every request.
// Tokens are handed out on an event loop, as aws-c-io's strategies do, and every retry is refused with
// AWS_IO_MAX_RETRIES_EXCEEDED, so the request fails with the error of its only attempt.
//
const SingleAttemptRetryStrategy = struct {
    // The SDK's retry strategy object (the vtable and the reference count).
    base: aws.aws_retry_strategy,

    // Where the token callbacks run.
    eventLoopGroup: *aws.aws_event_loop_group,

    //
    // The functions of the strategy.
    //
    var vtable: aws.aws_retry_strategy_vtable = .{
        .destroy = destroy,
        .acquire_token = acquireToken,
        .schedule_retry = scheduleRetry,
        .record_success = recordSuccess,
        .release_token = releaseToken,
    };

    //
    // Creates the strategy with one reference.
    //
    fn create(eventLoopGroup: *aws.aws_event_loop_group) !*SingleAttemptRetryStrategy {
        const self = try std.heap.smp_allocator.create(SingleAttemptRetryStrategy);
        self.* = .{
            .base = .{
                .allocator = aws.aws_default_allocator(),
                .vtable = &vtable,
                .ref_count = undefined,
                .impl = null,
            },
            .eventLoopGroup = eventLoopGroup,
        };
        self.base.impl = self;
        aws.aws_atomic_init_int(&self.base.ref_count, 1);
        return self;
    }

    //
    // Frees the strategy when its last reference is released.
    //
    fn destroy(strategy: [*c]aws.aws_retry_strategy) callconv(.c) void {
        const self: *SingleAttemptRetryStrategy = @ptrCast(@alignCast(strategy.*.impl.?));
        std.heap.smp_allocator.destroy(self);
    }

    //
    // Hands out a token: calls on_acquired from an event loop task.
    //
    fn acquireToken(strategy: [*c]aws.aws_retry_strategy, partition_id: [*c]const aws.aws_byte_cursor, on_acquired: ?*const aws.aws_retry_strategy_on_retry_token_acquired_fn, user_data: ?*anyopaque, timeout_ms: u64) callconv(.c) c_int {
        _ = partition_id;
        _ = timeout_ms;
        const self: *SingleAttemptRetryStrategy = @ptrCast(@alignCast(strategy.*.impl.?));
        const token = std.heap.smp_allocator.create(SingleAttemptRetryToken) catch {
            return aws.aws_raise_error(aws.AWS_ERROR_OOM);
        };
        token.* = .{
            .base = .{
                .allocator = aws.aws_default_allocator(),
                .retry_strategy = strategy,
                .ref_count = undefined,
                .impl = null,
            },
            .task = undefined,
            .onAcquired = on_acquired,
            .userData = user_data,
        };
        token.base.impl = token;
        aws.aws_atomic_init_int(&token.base.ref_count, 1);
        aws.aws_retry_strategy_acquire(strategy);
        aws.aws_task_init(&token.task, SingleAttemptRetryToken.onAcquireTask, token, "single_attempt_retry_token_acquired");
        aws.aws_event_loop_schedule_task_now(aws.aws_event_loop_group_get_next_loop(self.eventLoopGroup), &token.task);
        return aws.AWS_OP_SUCCESS;
    }

    //
    // Refuses the retry.
    //
    fn scheduleRetry(token: [*c]aws.aws_retry_token, error_type: aws.aws_retry_error_type, retry_ready: ?*const aws.aws_retry_strategy_on_retry_ready_fn, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = token;
        _ = error_type;
        _ = retry_ready;
        _ = user_data;
        return aws.aws_raise_error(aws.AWS_IO_MAX_RETRIES_EXCEEDED);
    }

    //
    // Nothing to record: there is no retry budget.
    //
    fn recordSuccess(token: [*c]aws.aws_retry_token) callconv(.c) c_int {
        _ = token;
        return aws.AWS_OP_SUCCESS;
    }

    //
    // Frees a token when its last reference is released.
    //
    fn releaseToken(token: [*c]aws.aws_retry_token) callconv(.c) void {
        const singleAttemptToken: *SingleAttemptRetryToken = @ptrCast(@alignCast(token.*.impl.?));
        const strategy = token.*.retry_strategy;
        std.heap.smp_allocator.destroy(singleAttemptToken);
        aws.aws_retry_strategy_release(strategy);
    }
};

//
// A token of SingleAttemptRetryStrategy.
//
const SingleAttemptRetryToken = struct {
    // The SDK's retry token object.
    base: aws.aws_retry_token,

    // The event loop task that calls onAcquired.
    task: aws.aws_task,

    // Called with the token once it is acquired.
    onAcquired: ?*const aws.aws_retry_strategy_on_retry_token_acquired_fn,

    // The user data of onAcquired.
    userData: ?*anyopaque,

    //
    // The event loop task: passes the token to the requester.
    //
    fn onAcquireTask(task: [*c]aws.aws_task, arg: ?*anyopaque, status: aws.aws_task_status) callconv(.c) void {
        _ = task;
        _ = status;
        const self: *SingleAttemptRetryToken = @ptrCast(@alignCast(arg.?));
        self.onAcquired.?(self.base.retry_strategy, aws.AWS_ERROR_SUCCESS, &self.base, self.userData);
    }
};

//
// The SDK objects of a client, created on its first request (when the region and credentials are resolved, like the
// SDK) and freed by S3Client.deinit.
//
const ClientRuntime = struct {
    // The region, owned.
    region: []u8,

    // The threads the SDK runs its I/O on.
    eventLoopGroup: *aws.aws_event_loop_group,

    // Resolves host names.
    hostResolver: *aws.aws_host_resolver,

    // Creates connections.
    clientBootstrap: *aws.aws_client_bootstrap,

    // Provides the credentials to the signer.
    credentialsProvider: *aws.aws_credentials_provider,

    // The retry strategy (one attempt per request).
    retryStrategy: *SingleAttemptRetryStrategy,

    // The S3 endpoint rules (the same rule set as the JavaScript SDK's endpoint resolver).
    endpointRuleEngine: *aws.aws_endpoints_rule_engine,

    // The aws-c-s3 client.
    s3Client: *S3ClientHandle,

    // Signs requests without a body (the SDK's default S3 signing: SigV4 with the payload hash).
    signingConfig: SigningConfigAws,

    // Signs requests with a body: the photosphereUnsignedPayload middleware of CloudStorage.buildClient, which sends
    // "UNSIGNED-PAYLOAD" as the payload hash of every request that has a body.
    unsignedPayloadSigningConfig: SigningConfigAws,

    // Guards the shutdown flags.
    mutex: aws.aws_mutex,

    // Signalled when a shutdown callback runs.
    signal: aws.aws_condition_variable,

    // True once the aws-c-s3 client has shut down.
    s3ClientShutDown: bool,

    // True once the event loop group has shut down (its threads have exited).
    eventLoopGroupShutDown: bool,

    //
    // Sets a shutdown flag and wakes the waiting thread.
    //
    fn raise(self: *ClientRuntime, flag: *bool) void {
        _ = aws.aws_mutex_lock(&self.mutex);
        flag.* = true;
        _ = aws.aws_condition_variable_notify_all(&self.signal);
        _ = aws.aws_mutex_unlock(&self.mutex);
    }

    //
    // Waits until a shutdown flag is set.
    //
    fn wait(self: *ClientRuntime, flag: *bool) void {
        _ = aws.aws_mutex_lock(&self.mutex);
        while (!flag.*) {
            _ = aws.aws_condition_variable_wait(&self.signal, &self.mutex);
        }
        _ = aws.aws_mutex_unlock(&self.mutex);
    }

    //
    // The shutdown callback of the aws-c-s3 client.
    //
    fn onS3ClientShutdown(user_data: ?*anyopaque) callconv(.c) void {
        const self: *ClientRuntime = @ptrCast(@alignCast(user_data.?));
        self.raise(&self.s3ClientShutDown);
    }

    //
    // The shutdown callback of the event loop group.
    //
    fn onEventLoopGroupShutdown(user_data: ?*anyopaque) callconv(.c) void {
        const self: *ClientRuntime = @ptrCast(@alignCast(user_data.?));
        self.raise(&self.eventLoopGroupShutDown);
    }
};

//
// The body of a request.
//
const RequestBody = union(enum) {
    // No body (the SDK's undefined request body: a command with no payload).
    none,

    // A body in memory, sent as it is and signed with UNSIGNED-PAYLOAD.
    bytes: []const u8,
};

//
// The body of a PUT_OBJECT meta request whose length is unknown: the part already read and the rest of the stream.
//
const IBodyStream = struct {
    // The first part, already read from the stream.
    firstPart: []const u8,

    // The rest of the stream.
    rest: *std.Io.Reader,
};

//
// One S3 operation to run.
//
const OperationRequest = struct {
    // The kind of meta request (DEFAULT sends the request as it is; PUT_OBJECT is the SDK's PutObject, which uploads
    // in parts when the body is larger than one part).
    type: aws.aws_s3_meta_request_type,

    // The operation name (for DEFAULT meta requests).
    operationName: []const u8,

    // The HTTP method.
    method: []const u8,

    // The bucket.
    bucket: []const u8,

    // The object key (empty for a request on the bucket).
    key: []const u8,

    // The encoded query string without the "?" (empty for none).
    query: []const u8,

    // Extra headers.
    headers: []const IHeader,

    // The body.
    body: RequestBody,

    // The part size for PUT_OBJECT (0 for the SDK's default).
    partSize: u64,

    // The largest number of connections the meta request uses at once (0 for the SDK's default).
    maxActiveConnections: u32,

    // The body sent with aws_s3_meta_request_poll_write for a PUT_OBJECT whose length is unknown (null for none).
    bodyStream: ?IBodyStream,
};

//
// The client: runs S3 operations with aws-c-s3.
//
//
// The key of an object, the input of the commands that only name one.
//
pub const IObjectKey = struct {
    // The bucket.
    Bucket: []const u8,

    // The object key.
    Key: []const u8,
};

//
// Input of GetObject.
//
pub const IGetObjectInput = struct {
    // The bucket.
    Bucket: []const u8,

    // The object key.
    Key: []const u8,

    // The byte range, such as "bytes=0-99" (null for the whole object).
    Range: ?[]const u8,
};

//
// Input of PutObject.
//
pub const IPutObjectInput = struct {
    // The bucket.
    Bucket: []const u8,

    // The object key.
    Key: []const u8,

    // The object data.
    Body: []const u8,

    // The content type (null for none).
    ContentType: ?[]const u8,

    // "*" writes only when the object does not exist (null for an unconditional write).
    IfNoneMatch: ?[]const u8,
};

//
// Input of DeleteObjects.
//
pub const IDeleteObjectsInput = struct {
    // The bucket.
    Bucket: []const u8,

    // The keys of the objects to delete.
    Keys: []const []const u8,
};

//
// Input of CopyObject.
//
pub const ICopyObjectInput = struct {
    // The destination bucket.
    Bucket: []const u8,

    // The source, as "bucket/key".
    CopySource: []const u8,

    // The destination key.
    Key: []const u8,
};

//
// A command sent to the client (TypeScript: the command objects passed to `S3Client.send`).
//
pub const S3Command = union(enum) {
    // ListObjectsV2Command.
    ListObjectsV2Command: ListObjectsV2Input,

    // HeadObjectCommand.
    HeadObjectCommand: IObjectKey,

    // GetObjectCommand.
    GetObjectCommand: IGetObjectInput,

    // PutObjectCommand.
    PutObjectCommand: IPutObjectInput,

    // DeleteObjectCommand.
    DeleteObjectCommand: IObjectKey,

    // DeleteObjectsCommand.
    DeleteObjectsCommand: IDeleteObjectsInput,

    // CopyObjectCommand.
    CopyObjectCommand: ICopyObjectInput,
};

//
// What `send` resolves to for a command.
//
pub const S3CommandOutput = union(enum) {
    // A command whose output is not read (PutObject, DeleteObject, DeleteObjects, CopyObject).
    none,

    // The output of ListObjectsV2.
    ListObjectsV2: ListObjectsV2Output,

    // The output of HeadObject.
    HeadObject: HeadObjectOutput,

    // The output of GetObject.
    GetObject: GetObjectOutput,
};

//
// Answers the client's commands in place of the SDK. The TypeScript tests replace the client with an
// object whose `send` answers each command; a Zig test sets this on the client for the same effect.
//
pub const ISend = struct {
    // Passed to `function`.
    context: *anyopaque,

    // Answers one command.
    function: *const fn (context: *anyopaque, command: S3Command) anyerror!S3CommandOutput,
};

//
// Throws an S3 service exception (TypeScript: an error with `name` and `$metadata.httpStatusCode`), for an
// ISend answering a command with an error.
//
pub fn throwServiceException(name: []const u8, message: []const u8, httpStatusCode: u16) anyerror {
    last_http_status_code = httpStatusCode;
    errors.recordError(name, "{s}", .{message});
    return error.Thrown;
}

pub const S3Client = struct {
    // The client configuration.
    config: IS3ClientConfig,

    // Answers the commands in place of the SDK when set (null in normal use; see ISend).
    send: ?ISend,

    // Guards the creation of `runtime`.
    mutex: aws.aws_mutex,

    // The SDK objects (null until the first request).
    runtime: ?*ClientRuntime,

    //
    // Creates a client (TypeScript: `new S3Client(config)`).
    //
    pub fn init(io: std.Io, config: IS3ClientConfig) S3Client {
        initLibrary(io);
        var client: S3Client = .{
            .config = config,
            .send = null,
            .mutex = undefined,
            .runtime = null,
        };
        _ = aws.aws_mutex_init(&client.mutex);
        return client;
    }

    //
    // Shuts the SDK client down and waits until its threads have exited.
    //
    pub fn deinit(self: *S3Client) void {
        if (self.runtime) |runtime| {
            _ = aws.aws_s3_client_release(runtime.s3Client);
            runtime.wait(&runtime.s3ClientShutDown);
            _ = aws.aws_endpoints_rule_engine_release(runtime.endpointRuleEngine);
            _ = aws.aws_credentials_provider_release(runtime.credentialsProvider);
            aws.aws_retry_strategy_release(&runtime.retryStrategy.base);
            aws.aws_client_bootstrap_release(runtime.clientBootstrap);
            aws.aws_host_resolver_release(runtime.hostResolver);
            aws.aws_event_loop_group_release(runtime.eventLoopGroup);
            runtime.wait(&runtime.eventLoopGroupShutDown);
            aws.aws_condition_variable_clean_up(&runtime.signal);
            aws.aws_mutex_clean_up(&runtime.mutex);
            std.heap.smp_allocator.free(runtime.region);
            std.heap.smp_allocator.destroy(runtime);
            self.runtime = null;
        }
        aws.aws_mutex_clean_up(&self.mutex);
    }

    //
    // Gets the credentials: from the configuration or from the environment (the SDK's default provider chain).
    //
    fn resolveCredentials(self: *S3Client) !ICredentials {
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
    // Gets the SDK objects, creating them on the first request.
    //
    fn getRuntime(self: *S3Client) !*ClientRuntime {
        _ = aws.aws_mutex_lock(&self.mutex);
        defer _ = aws.aws_mutex_unlock(&self.mutex);
        if (self.runtime) |runtime| {
            return runtime;
        }
        const credentials = try self.resolveCredentials();
        const region = try self.resolveRegion();
        const runtime = try createRuntime(credentials, region);
        self.runtime = runtime;
        return runtime;
    }

    //
    // Creates the SDK objects of a client.
    //
    fn createRuntime(credentials: ICredentials, region: []const u8) !*ClientRuntime {
        const allocator = aws.aws_default_allocator();
        const runtime = try std.heap.smp_allocator.create(ClientRuntime);
        runtime.region = try std.heap.smp_allocator.dupe(u8, region);
        runtime.s3ClientShutDown = false;
        runtime.eventLoopGroupShutDown = false;
        _ = aws.aws_mutex_init(&runtime.mutex);
        _ = aws.aws_condition_variable_init(&runtime.signal);

        const eventLoopGroupShutdown: aws.aws_shutdown_callback_options = .{
            .shutdown_callback_fn = ClientRuntime.onEventLoopGroupShutdown,
            .shutdown_callback_user_data = runtime,
        };
        var eventLoopGroupOptions = std.mem.zeroes(aws.aws_event_loop_group_options);
        eventLoopGroupOptions.shutdown_options = &eventLoopGroupShutdown;
        runtime.eventLoopGroup = aws.aws_event_loop_group_new(allocator, &eventLoopGroupOptions) orelse {
            return throwLastSdkError();
        };

        var hostResolverOptions = std.mem.zeroes(aws.aws_host_resolver_default_options);
        hostResolverOptions.max_entries = 8;
        hostResolverOptions.el_group = runtime.eventLoopGroup;
        runtime.hostResolver = aws.aws_host_resolver_new_default(allocator, &hostResolverOptions) orelse {
            return throwLastSdkError();
        };

        var bootstrapOptions = std.mem.zeroes(aws.aws_client_bootstrap_options);
        bootstrapOptions.event_loop_group = runtime.eventLoopGroup;
        bootstrapOptions.host_resolver = runtime.hostResolver;
        runtime.clientBootstrap = aws.aws_client_bootstrap_new(allocator, &bootstrapOptions) orelse {
            return throwLastSdkError();
        };

        var credentialsOptions = std.mem.zeroes(aws.aws_credentials_provider_static_options);
        credentialsOptions.access_key_id = cursorOf(credentials.accessKeyId);
        credentialsOptions.secret_access_key = cursorOf(credentials.secretAccessKey);
        if (credentials.sessionToken) |sessionToken| {
            credentialsOptions.session_token = cursorOf(sessionToken);
        }
        runtime.credentialsProvider = aws.aws_credentials_provider_new_static(allocator, &credentialsOptions) orelse {
            return throwLastSdkError();
        };

        runtime.retryStrategy = try SingleAttemptRetryStrategy.create(runtime.eventLoopGroup);

        runtime.endpointRuleEngine = aws.aws_s3_endpoint_resolver_new(allocator) orelse {
            return throwLastSdkError();
        };

        aws.aws_s3_init_default_signing_config(@ptrCast(&runtime.signingConfig), cursorOf(runtime.region), runtime.credentialsProvider);
        runtime.unsignedPayloadSigningConfig = runtime.signingConfig;
        runtime.unsignedPayloadSigningConfig.signed_body_value = aws.g_aws_signed_body_value_unsigned_payload;

        var clientConfig = std.mem.zeroes(aws.aws_s3_client_config);
        clientConfig.region = cursorOf(runtime.region);
        clientConfig.client_bootstrap = runtime.clientBootstrap;
        clientConfig.signing_config = runtime.signingConfig.sdk();
        // The connectionTimeout of the request handler CloudStorage.buildClient configures.
        clientConfig.connect_timeout_ms = 600000;
        // maxAttempts: 1.
        clientConfig.retry_strategy = &runtime.retryStrategy.base;
        clientConfig.shutdown_callback = ClientRuntime.onS3ClientShutdown;
        clientConfig.shutdown_callback_user_data = runtime;
        runtime.s3Client = aws.aws_s3_client_new(allocator, &clientConfig) orelse {
            return throwLastSdkError();
        };
        return runtime;
    }

    //
    // Resolves the endpoint of a request on a bucket with the S3 endpoint rules (virtual-hosted-style unless the
    // endpoint host is an IP address or the bucket name is not a valid host name label, like the JavaScript SDK,
    // which CloudStorage creates without forcePathStyle). Returns the URL, for example "http://127.0.0.1:9000/bucket"
    // or "https://bucket.s3.us-east-1.amazonaws.com".
    //
    pub fn resolveEndpoint(self: *S3Client, allocator: std.mem.Allocator, bucket: []const u8) ![]const u8 {
        const runtime = try self.getRuntime();
        const sdkAllocator = aws.aws_default_allocator();
        const context = aws.aws_endpoints_request_context_new(sdkAllocator) orelse {
            return throwLastSdkError();
        };
        defer _ = aws.aws_endpoints_request_context_release(context);
        if (aws.aws_endpoints_request_context_add_string(sdkAllocator, context, cursorOf("Region"), cursorOf(runtime.region)) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        if (aws.aws_endpoints_request_context_add_string(sdkAllocator, context, cursorOf("Bucket"), cursorOf(bucket)) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        if (self.config.endpoint) |endpoint| {
            if (aws.aws_endpoints_request_context_add_string(sdkAllocator, context, cursorOf("Endpoint"), cursorOf(endpoint)) != aws.AWS_OP_SUCCESS) {
                return throwLastSdkError();
            }
        }
        var resolvedEndpoint: ?*aws.aws_endpoints_resolved_endpoint = null;
        if (aws.aws_endpoints_rule_engine_resolve(runtime.endpointRuleEngine, context, &resolvedEndpoint) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        defer _ = aws.aws_endpoints_resolved_endpoint_release(resolvedEndpoint);
        if (aws.aws_endpoints_resolved_endpoint_get_type(resolvedEndpoint) == aws.AWS_ENDPOINTS_RESOLVED_ERROR) {
            var message: aws.aws_byte_cursor = undefined;
            _ = aws.aws_endpoints_resolved_endpoint_get_error(resolvedEndpoint, &message);
            last_http_status_code = 0;
            return errors.throwError("{s}", .{sliceOf(message)});
        }
        var url: aws.aws_byte_cursor = undefined;
        if (aws.aws_endpoints_resolved_endpoint_get_url(resolvedEndpoint, &url) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        return allocator.dupe(u8, sliceOf(url));
    }

    //
    // Runs one operation as an aws-c-s3 meta request and waits for it. Returns the finished call (response headers
    // and body) when it succeeded and throws the S3 or SDK error when it did not.
    //
    fn run(self: *S3Client, allocator: std.mem.Allocator, request: OperationRequest) !*MetaRequestCall {
        const runtime = try self.getRuntime();
        const sdkAllocator = aws.aws_default_allocator();

        const url = try self.resolveEndpoint(allocator, request.bucket);
        var endpoint: aws.aws_uri = undefined;
        var urlCursor = cursorOf(url);
        if (aws.aws_uri_init_parse(&endpoint, sdkAllocator, &urlCursor) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        defer aws.aws_uri_clean_up(&endpoint);

        // The path of the endpoint (the bucket for path-style requests) then the URI-encoded key.
        var path: aws.aws_byte_buf = undefined;
        if (aws.aws_byte_buf_init(&path, sdkAllocator, 256) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        defer aws.aws_byte_buf_clean_up(&path);
        var endpointPath = endpoint.path;
        if (endpointPath.len > 0 and endpointPath.ptr[endpointPath.len - 1] == '/') {
            endpointPath.len -= 1;
        }
        var keyCursor = cursorOf(request.key);
        if (aws.aws_byte_buf_append_dynamic(&path, &endpointPath) != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_byte_dynamic(&path, '/') != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_encoding_uri_path(&path, &keyCursor) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        if (request.query.len > 0) {
            var queryCursor = cursorOf(request.query);
            if (aws.aws_byte_buf_append_byte_dynamic(&path, '?') != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_dynamic(&path, &queryCursor) != aws.AWS_OP_SUCCESS) {
                return throwLastSdkError();
            }
        }

        const message = aws.aws_http_message_new_request(sdkAllocator) orelse {
            return throwLastSdkError();
        };
        defer _ = aws.aws_http_message_release(message);
        if (aws.aws_http_message_set_request_method(message, cursorOf(request.method)) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        if (aws.aws_http_message_set_request_path(message, aws.aws_byte_cursor_from_buf(&path)) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        try addHeader(message, "Host", sliceOf(endpoint.authority));
        for (request.headers) |requestHeader| {
            try addHeader(message, requestHeader.name, requestHeader.value);
        }

        var options = std.mem.zeroes(aws.aws_s3_meta_request_options);
        options.type = request.type;
        options.operation_name = cursorOf(request.operationName);
        options.message = message;
        options.endpoint = &endpoint;
        options.signing_config = runtime.signingConfig.sdk();
        options.part_size = request.partSize;
        options.multipart_upload_threshold = request.partSize;
        options.max_active_connections_override = request.maxActiveConnections;

        var bodyStream: ?*aws.aws_input_stream = null;
        defer {
            if (bodyStream) |stream| {
                _ = aws.aws_input_stream_release(stream);
            }
        }
        var bodyCursor: aws.aws_byte_cursor = undefined;
        switch (request.body) {
            .none => {},
            .bytes => |bytes| {
                try addHeader(message, "Content-Length", try std.fmt.allocPrint(allocator, "{d}", .{bytes.len}));
                options.signing_config = runtime.unsignedPayloadSigningConfig.sdk();
                if (request.type == aws.AWS_S3_META_REQUEST_TYPE_DEFAULT) {
                    options.request_body = cursorOf(bytes);
                }
                else {
                    bodyCursor = cursorOf(bytes);
                    bodyStream = aws.aws_input_stream_new_from_cursor(sdkAllocator, &bodyCursor) orelse {
                        return throwLastSdkError();
                    };
                    aws.aws_http_message_set_body_stream(message, bodyStream);
                }
            },
        }
        if (request.bodyStream != null) {
            options.signing_config = runtime.unsignedPayloadSigningConfig.sdk();
            options.send_using_async_writes = true;
        }

        const call = try allocator.create(MetaRequestCall);
        call.init(allocator);
        defer call.deinit();
        options.user_data = call;
        options.headers_callback = MetaRequestCall.onHeaders;
        options.body_callback = MetaRequestCall.onBody;
        options.finish_callback = MetaRequestCall.onFinish;
        options.shutdown_callback = MetaRequestCall.onShutdown;

        const metaRequest = aws.aws_s3_client_make_meta_request(runtime.s3Client, &options) orelse {
            return throwLastSdkError();
        };

        var streamError: ?anyerror = null;
        if (request.bodyStream) |stream| {
            writeBodyStream(metaRequest, call, stream) catch |err| {
                streamError = err;
                aws.aws_s3_meta_request_cancel(metaRequest);
            };
        }

        call.wait(&call.finished, false);
        _ = aws.aws_s3_meta_request_release(metaRequest);
        call.wait(&call.shutDown, false);

        if (streamError) |err| {
            return err;
        }
        if (call.outOfMemory) {
            return error.OutOfMemory;
        }
        if (call.errorCode != 0) {
            return throwResultError(allocator, call);
        }
        return call;
    }

    //
    // ListObjectsV2.
    //
    pub fn listObjectsV2(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, input: ListObjectsV2Input) !ListObjectsV2Output {
        if (self.send) |send| {
            return (try send.function(send.context, .{ .ListObjectsV2Command = input })).ListObjectsV2;
        }
        _ = io;
        var query: std.ArrayList(u8) = .empty;
        try query.appendSlice(allocator, "list-type=2");
        if (input.Delimiter) |delimiter| {
            try appendQueryParameter(allocator, &query, "delimiter", delimiter);
        }
        if (input.MaxKeys) |maxKeys| {
            try appendQueryParameter(allocator, &query, "max-keys", try std.fmt.allocPrint(allocator, "{d}", .{maxKeys}));
        }
        try appendQueryParameter(allocator, &query, "prefix", input.Prefix);
        if (input.ContinuationToken) |continuationToken| {
            try appendQueryParameter(allocator, &query, "continuation-token", continuationToken);
        }
        const call = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "ListObjectsV2",
            .method = "GET",
            .bucket = input.Bucket,
            .key = "",
            .query = query.items,
            .headers = &.{},
            .body = .none,
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
        return parseListObjectsV2(allocator, call.body.items);
    }

    //
    // HeadObject.
    //
    pub fn headObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8) !HeadObjectOutput {
        if (self.send) |send| {
            return (try send.function(send.context, .{ .HeadObjectCommand = .{ .Bucket = bucket, .Key = key } })).HeadObject;
        }
        _ = io;
        const call = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "HeadObject",
            .method = "HEAD",
            .bucket = bucket,
            .key = key,
            .query = "",
            .headers = &.{},
            .body = .none,
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
        var contentLength: u64 = 0;
        if (call.header("content-length")) |lengthText| {
            contentLength = std.fmt.parseInt(u64, lengthText, 10) catch 0;
        }
        var lastModified: ?i64 = null;
        if (call.header("last-modified")) |dateText| {
            lastModified = parseHttpDate(dateText);
        }
        return .{
            .ContentType = call.header("content-type"),
            .ContentLength = contentLength,
            .LastModified = lastModified,
        };
    }

    //
    // GetObject, optionally for a byte range such as "bytes=0-99" (one request, like the JavaScript SDK's
    // GetObjectCommand).
    //
    pub fn getObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, range: ?[]const u8) !GetObjectOutput {
        if (self.send) |send| {
            return (try send.function(send.context, .{ .GetObjectCommand = .{ .Bucket = bucket, .Key = key, .Range = range } })).GetObject;
        }
        _ = io;
        var headers: std.ArrayList(IHeader) = .empty;
        if (range) |rangeValue| {
            try headers.append(allocator, .{
                .name = "Range",
                .value = rangeValue,
            });
        }
        const call = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "GetObject",
            .method = "GET",
            .bucket = bucket,
            .key = key,
            .query = "",
            .headers = headers.items,
            .body = .none,
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
        return .{
            .Body = if (call.body.items.len == 0) null else call.body.items,
            .ContentRange = call.header("content-range"),
        };
    }

    //
    // PutObject (ifNoneMatch is the IfNoneMatch input: "*" writes only when the object does not exist).
    //
    pub fn putObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8, body: []const u8, contentType: ?[]const u8, ifNoneMatch: ?[]const u8) !void {
        if (self.send) |send| {
            _ = try send.function(send.context, .{ .PutObjectCommand = .{ .Bucket = bucket, .Key = key, .Body = body, .ContentType = contentType, .IfNoneMatch = ifNoneMatch } });
            return;
        }
        _ = io;
        var headers: std.ArrayList(IHeader) = .empty;
        if (contentType) |contentTypeValue| {
            try headers.append(allocator, .{
                .name = "Content-Type",
                .value = contentTypeValue,
            });
        }
        if (ifNoneMatch) |ifNoneMatchValue| {
            try headers.append(allocator, .{
                .name = "If-None-Match",
                .value = ifNoneMatchValue,
            });
        }
        _ = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "PutObject",
            .method = "PUT",
            .bucket = bucket,
            .key = key,
            .query = "",
            .headers = headers.items,
            .body = .{ .bytes = body },
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
    }

    //
    // DeleteObject.
    //
    pub fn deleteObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, key: []const u8) !void {
        if (self.send) |send| {
            _ = try send.function(send.context, .{ .DeleteObjectCommand = .{ .Bucket = bucket, .Key = key } });
            return;
        }
        _ = io;
        _ = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "DeleteObject",
            .method = "DELETE",
            .bucket = bucket,
            .key = key,
            .query = "",
            .headers = &.{},
            .body = .none,
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
    }

    //
    // DeleteObjects (up to 1000 keys). The body is the XML the SDK's DeleteObjects serializer writes, with the
    // Content-MD5 S3 requires computed by the SDK (aws-c-cal).
    //
    pub fn deleteObjects(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, keys: []const []const u8) !void {
        if (self.send) |send| {
            _ = try send.function(send.context, .{ .DeleteObjectsCommand = .{ .Bucket = bucket, .Keys = keys } });
            return;
        }
        _ = io;
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
        for (keys) |key| {
            try body.appendSlice(allocator, "<Object><Key>");
            try appendXmlEscaped(allocator, &body, key);
            try body.appendSlice(allocator, "</Key></Object>");
        }
        try body.appendSlice(allocator, "</Delete>");
        const headers = [_]IHeader{
            .{
                .name = "Content-MD5",
                .value = try contentMd5(allocator, body.items),
            },
            .{
                .name = "Content-Type",
                .value = "application/xml",
            },
        };
        _ = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "DeleteObjects",
            .method = "POST",
            .bucket = bucket,
            .key = "",
            .query = "delete=",
            .headers = &headers,
            .body = .{ .bytes = body.items },
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
    }

    //
    // CopyObject (copySource is "<bucket>/<key>"). The SDK reports an error in a 200 response as a failure.
    //
    pub fn copyObject(self: *S3Client, allocator: std.mem.Allocator, io: std.Io, bucket: []const u8, copySource: []const u8, key: []const u8) !void {
        if (self.send) |send| {
            _ = try send.function(send.context, .{ .CopyObjectCommand = .{ .Bucket = bucket, .CopySource = copySource, .Key = key } });
            return;
        }
        _ = io;
        var encodedCopySource: aws.aws_byte_buf = undefined;
        if (aws.aws_byte_buf_init(&encodedCopySource, aws.aws_default_allocator(), copySource.len) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        defer aws.aws_byte_buf_clean_up(&encodedCopySource);
        var copySourceCursor = cursorOf(copySource);
        if (aws.aws_byte_buf_append_encoding_uri_path(&encodedCopySource, &copySourceCursor) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        const headers = [_]IHeader{
            .{
                .name = "x-amz-copy-source",
                .value = try allocator.dupe(u8, sliceOf(aws.aws_byte_cursor_from_buf(&encodedCopySource))),
            },
        };
        _ = try self.run(allocator, .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_DEFAULT,
            .operationName = "CopyObject",
            .method = "PUT",
            .bucket = bucket,
            .key = key,
            .query = "",
            .headers = &headers,
            .body = .none,
            .partSize = 0,
            .maxActiveConnections = 0,
            .bodyStream = null,
        });
    }
};

//
// Adds a header to an SDK HTTP message (the SDK copies the name and value).
//
fn addHeader(message: *aws.aws_http_message, name: []const u8, value: []const u8) !void {
    const messageHeader: aws.aws_http_header = .{
        .name = cursorOf(name),
        .value = cursorOf(value),
        .compression = aws.AWS_HTTP_HEADER_COMPRESSION_USE_CACHE,
    };
    if (aws.aws_http_message_add_header(message, messageHeader) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
}

//
// Appends "&name=value" to a query string, with the name and value URI-encoded by the SDK.
//
fn appendQueryParameter(allocator: std.mem.Allocator, query: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    var buffer: aws.aws_byte_buf = undefined;
    if (aws.aws_byte_buf_init(&buffer, aws.aws_default_allocator(), name.len + value.len + 2) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    defer aws.aws_byte_buf_clean_up(&buffer);
    var nameCursor = cursorOf(name);
    var valueCursor = cursorOf(value);
    if (aws.aws_byte_buf_append_byte_dynamic(&buffer, '&') != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_encoding_uri_param(&buffer, &nameCursor) != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_byte_dynamic(&buffer, '=') != aws.AWS_OP_SUCCESS or aws.aws_byte_buf_append_encoding_uri_param(&buffer, &valueCursor) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    try query.appendSlice(allocator, sliceOf(aws.aws_byte_cursor_from_buf(&buffer)));
}

//
// Appends text to an XML document with the five XML special characters escaped (what the SDK's XML serializer does
// with the keys of DeleteObjects).
//
pub fn appendXmlEscaped(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
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
}

//
// The base64 MD5 of a body (the Content-Md5 header), computed with the SDK (aws-c-cal and aws-c-common).
//
pub fn contentMd5(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const sdkAllocator = aws.aws_default_allocator();
    var digest: aws.aws_byte_buf = undefined;
    if (aws.aws_byte_buf_init(&digest, sdkAllocator, aws.AWS_MD5_LEN) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    defer aws.aws_byte_buf_clean_up(&digest);
    var bodyCursor = cursorOf(body);
    if (aws.aws_md5_compute(sdkAllocator, &bodyCursor, &digest, 0) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    var encoded: aws.aws_byte_buf = undefined;
    if (aws.aws_byte_buf_init(&encoded, sdkAllocator, 32) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    defer aws.aws_byte_buf_clean_up(&encoded);
    const digestCursor = aws.aws_byte_cursor_from_buf(&digest);
    if (aws.aws_base64_encode(&digestCursor, &encoded) != aws.AWS_OP_SUCCESS) {
        return throwLastSdkError();
    }
    return allocator.dupe(u8, sliceOf(aws.aws_byte_cursor_from_buf(&encoded)));
}

//
// Parses an HTTP date such as "Wed, 12 Oct 2009 17:50:00 GMT" into milliseconds since the Unix epoch with the SDK's
// date parser (null when it is not a valid date).
//
pub fn parseHttpDate(text: []const u8) ?i64 {
    var dateTime: aws.aws_date_time = undefined;
    var textCursor = cursorOf(text);
    if (aws.aws_date_time_init_from_str_cursor(&dateTime, &textCursor, aws.AWS_DATE_FORMAT_RFC822) != aws.AWS_OP_SUCCESS) {
        return null;
    }
    return @intCast(aws.aws_date_time_as_millis(&dateTime));
}

//
// What the XML parser callbacks of parseListObjectsV2 collect.
//
const ListObjectsV2Parse = struct {
    // Allocates the result.
    allocator: std.mem.Allocator,

    // The keys of the <Contents> elements.
    contents: std.ArrayList(S3Object),

    // The prefixes of the <CommonPrefixes> elements.
    commonPrefixes: std.ArrayList(CommonPrefix),

    // The <NextContinuationToken>.
    nextContinuationToken: ?[]const u8,

    // The <IsTruncated>.
    isTruncated: bool,

    // The first error (a Zig error cannot cross the C callbacks).
    failure: ?anyerror,

    //
    // Gets the parse state from the user data of a callback.
    //
    fn fromUserData(user_data: ?*anyopaque) *ListObjectsV2Parse {
        return @ptrCast(@alignCast(user_data.?));
    }

    //
    // Gets the unescaped text of an element.
    //
    fn text(self: *ListObjectsV2Parse, node: ?*aws.aws_xml_node) ![]const u8 {
        var body: aws.aws_byte_cursor = undefined;
        if (aws.aws_xml_node_as_body(node, &body) != aws.AWS_OP_SUCCESS) {
            return throwLastSdkError();
        }
        return unescapeXml(self.allocator, body);
    }

    //
    // Records the first failure and tells the parser to stop.
    //
    fn fail(self: *ListObjectsV2Parse, err: anyerror) c_int {
        if (self.failure == null) {
            self.failure = err;
        }
        return aws.aws_raise_error(aws.AWS_ERROR_INVALID_XML);
    }

    //
    // The root element (<ListBucketResult>).
    //
    fn onRoot(node: ?*aws.aws_xml_node, user_data: ?*anyopaque) callconv(.c) c_int {
        return aws.aws_xml_node_traverse(node, onResultChild, user_data);
    }

    //
    // A child of <ListBucketResult>.
    //
    fn onResultChild(node: ?*aws.aws_xml_node, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = fromUserData(user_data);
        const name = sliceOf(aws.aws_xml_node_get_name(node));
        if (std.mem.eql(u8, name, "Contents")) {
            return aws.aws_xml_node_traverse(node, onContentsChild, user_data);
        }
        if (std.mem.eql(u8, name, "CommonPrefixes")) {
            return aws.aws_xml_node_traverse(node, onCommonPrefixesChild, user_data);
        }
        if (std.mem.eql(u8, name, "NextContinuationToken")) {
            self.nextContinuationToken = self.text(node) catch |err| {
                return self.fail(err);
            };
        }
        else if (std.mem.eql(u8, name, "IsTruncated")) {
            const value = self.text(node) catch |err| {
                return self.fail(err);
            };
            self.isTruncated = std.mem.eql(u8, value, "true");
        }
        return aws.AWS_OP_SUCCESS;
    }

    //
    // A child of <Contents>.
    //
    fn onContentsChild(node: ?*aws.aws_xml_node, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = fromUserData(user_data);
        if (std.mem.eql(u8, sliceOf(aws.aws_xml_node_get_name(node)), "Key")) {
            const key = self.text(node) catch |err| {
                return self.fail(err);
            };
            self.contents.append(self.allocator, .{ .Key = key }) catch |err| {
                return self.fail(err);
            };
        }
        return aws.AWS_OP_SUCCESS;
    }

    //
    // A child of <CommonPrefixes>.
    //
    fn onCommonPrefixesChild(node: ?*aws.aws_xml_node, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = fromUserData(user_data);
        if (std.mem.eql(u8, sliceOf(aws.aws_xml_node_get_name(node)), "Prefix")) {
            const prefix = self.text(node) catch |err| {
                return self.fail(err);
            };
            self.commonPrefixes.append(self.allocator, .{ .Prefix = prefix }) catch |err| {
                return self.fail(err);
            };
        }
        return aws.AWS_OP_SUCCESS;
    }
};

//
// Parses the XML of a ListObjectsV2 response with the SDK's XML parser.
//
pub fn parseListObjectsV2(allocator: std.mem.Allocator, xml: []const u8) !ListObjectsV2Output {
    var parse: ListObjectsV2Parse = .{
        .allocator = allocator,
        .contents = .empty,
        .commonPrefixes = .empty,
        .nextContinuationToken = null,
        .isTruncated = false,
        .failure = null,
    };
    const options: aws.aws_xml_parser_options = .{
        .doc = cursorOf(xml),
        .max_depth = 16,
        .on_root_encountered = ListObjectsV2Parse.onRoot,
        .user_data = &parse,
    };
    if (aws.aws_xml_parse(aws.aws_default_allocator(), &options) != aws.AWS_OP_SUCCESS) {
        if (parse.failure) |err| {
            return err;
        }
        return throwLastSdkError();
    }
    return .{
        .Contents = if (parse.contents.items.len > 0) parse.contents.items else null,
        .CommonPrefixes = if (parse.commonPrefixes.items.len > 0) parse.commonPrefixes.items else null,
        .NextContinuationToken = parse.nextContinuationToken,
        .IsTruncated = parse.isTruncated,
    };
}

//
// Sends the body of a PUT_OBJECT meta request whose length is unknown with aws_s3_meta_request_poll_write, from the
// calling thread, so reading the stream never blocks one of the SDK's threads: the part already read, then the rest of
// the stream.
//
fn writeBodyStream(metaRequest: *MetaRequestHandle, call: *MetaRequestCall, body: IBodyStream) !void {
    if (!try pollWrite(metaRequest, call, body.firstPart, false)) {
        return;
    }
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try body.rest.readSliceShort(&chunk);
        const endOfStream = count < chunk.len;
        if (!try pollWrite(metaRequest, call, chunk[0..count], endOfStream)) {
            return;
        }
        if (endOfStream) {
            return;
        }
    }
}

//
// Writes data to a meta request, waiting whenever the SDK is not ready for more. Returns false when the meta request
// has failed (it then finishes by itself and its finish callback carries the error).
//
fn pollWrite(metaRequest: *MetaRequestHandle, call: *MetaRequestCall, data: []const u8, endOfStream: bool) !bool {
    var remaining = data;
    while (true) {
        const result = aws.aws_s3_meta_request_poll_write(metaRequest, cursorOf(remaining), endOfStream, MetaRequestCall.onWritable, call);
        if (result.is_pending) {
            call.wait(&call.writable, true);
            continue;
        }
        if (result.error_code != 0) {
            return false;
        }
        remaining = remaining[result.bytes_processed..];
        if (remaining.len == 0) {
            return true;
        }
    }
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

    // The number of parts uploaded concurrently (the meta request's max_active_connections_override).
    queueSize: u32,
};

//
// Uploads a buffer or a stream with the SDK's PutObject (an aws-c-s3 PUT_OBJECT meta request), which sends one
// PutObject when the body fits in one part and a multipart upload otherwise (TypeScript:
// `new Upload({ client, params, partSize, queueSize }).done()` from @aws-sdk/lib-storage).
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
    // Runs the upload. A stream is read one part ahead, like lib-storage does: when it ends within the first part its
    // length is known and the SDK sends it as one PutObject, otherwise the SDK uploads it in parts (a stream whose
    // length is unknown is always a multipart upload in aws-c-s3). The first part is held in a page-allocated buffer
    // so large uploads do not grow the caller's arena.
    //
    pub fn done(self: *Upload, allocator: std.mem.Allocator, io: std.Io) !void {
        _ = io;
        const params = self.options.params;
        var headers: std.ArrayList(IHeader) = .empty;
        if (params.ContentType) |contentType| {
            try headers.append(allocator, .{
                .name = "Content-Type",
                .value = contentType,
            });
        }
        var request: OperationRequest = .{
            .type = aws.AWS_S3_META_REQUEST_TYPE_PUT_OBJECT,
            .operationName = "PutObject",
            .method = "PUT",
            .bucket = params.Bucket,
            .key = params.Key,
            .query = "",
            .headers = headers.items,
            .body = .none,
            .partSize = self.options.partSize,
            // queueSize: the number of parts uploaded at once.
            .maxActiveConnections = self.options.queueSize,
            .bodyStream = null,
        };
        switch (params.Body) {
            .buffer => |buffer| {
                request.body = .{ .bytes = buffer };
                _ = try self.options.client.run(allocator, request);
            },
            .stream => |stream| {
                const partSize: usize = @intCast(self.options.partSize);
                const firstPart = try std.heap.page_allocator.alloc(u8, partSize);
                defer std.heap.page_allocator.free(firstPart);
                const count = try stream.readSliceShort(firstPart);
                const endOfStream = count < partSize or (stream.peekByte() catch |err| switch (err) {
                    error.EndOfStream => null,
                    else => return err,
                }) == null;
                if (endOfStream) {
                    request.body = .{ .bytes = firstPart[0..count] };
                }
                else {
                    request.bodyStream = .{
                        .firstPart = firstPart,
                        .rest = stream,
                    };
                }
                _ = try self.options.client.run(allocator, request);
            },
        }
    }
};
