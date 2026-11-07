# JSON in the Zig code

Photosphere's Zig code writes and reads JSON through `std.json`, never by assembling or searching JSON text. Text built from string literals and format strings does not escape what it interpolates, so a quote or a backslash in a path or an error message makes it invalid. It also drifts from the struct that reads it back. A search for a fragment such as `"socket":` breaks as soon as the field order or the spacing changes.

## Writing JSON

- Write JSON from a named struct with `ziggy.json.stringify(allocator, value)`, or `utils.json.stringify` in a package that imports `utils-zig`. Both write compact JSON and leave out optional fields that are null.
- Write a constant message with `comptime ziggy.json.stringifyComptime(value)`. Inside a runtime function the call must be marked `comptime`, or it fails with "unable to resolve comptime value".
- Put JSON text that is already built into a value as `json.Raw{ .text = ... }`. It is written as it is, so its bytes are kept.
- Pass `.emit_null_optional_fields = true` to `std.json.Stringify.valueAlloc` (or `std.json.fmt`) whenever a null must appear in the output. Pass it explicitly, so a change to the library's default cannot change the output.
- A log line is text for a person: write its values with a format string, never as JSON.

## Reading JSON

- Read JSON with `std.json.parseFromSlice` or `std.json.parseFromSliceLeaky` into a named struct.
- Pass `.ignore_unknown_fields = true` where the sender adds fields the reader does not need.
- Pass `.parse_numbers = false` to keep each number of a `std.json.Value` as its original text, so it is written back byte for byte.
- A message that Photosphere's own code made and that does not parse is a bug: panic with a message that names the text.

## The native Linux app

`apps/photosphere/native/linux/src/main.zig` is built by Ziggy's build with only the `ziggy-native-linux` import, so it cannot reach `ziggy.json`. It uses `std.json` directly: `comptime std.fmt.comptimePrint("{f}", .{std.json.fmt(value, .{})})` for a constant reply.

## Exceptions

- `bdb-zig`'s `js-value.zig` and `json-stable-stringify.zig`, and `mcp-zig`'s `protocol.zig`, write `BsonValue`s the way JavaScript's `JSON.stringify` and the npm `json-stable-stringify` package do, byte for byte: JavaScript's number formatting, lone-surrogate escaping and key sorting. The hashes of stored records depend on that output, and `std.json` formats some numbers differently (`1e21` as `1000000000000000000000` where JavaScript writes `1e+21`).
- Test files keep literal JSON for fixtures and expected output, so a test checks exact bytes. Test code that builds JSON uses `std.json` like any other code.
- The fragments given to Ziggy's `FakeNativeApp` (`indexOfContaining`, `expectMessageContaining`, `countContaining`, `removeContaining`) are substring patterns, because it matches messages only by substring.
- Log and error texts that quote a value, such as `holdAwake needs {"awake": true or false}`, are messages to a person, not JSON.
