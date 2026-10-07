const serialization_zig = @import("serialization-zig");
const BsonValue = serialization_zig.bson.BsonValue;

//
// Jest's toEqual: deep equality that ignores properties whose value is undefined and the order of properties.
//
pub fn toEqual(actual: BsonValue, expected: BsonValue) bool {
    if (actual == .document and expected == .document) {
        for (expected.document.fields.items) |field| {
            if (field.value == .undefined) {
                continue;
            }
            if (!toEqual(actual.document.get(field.key) orelse .undefined, field.value)) {
                return false;
            }
        }
        for (actual.document.fields.items) |field| {
            if (field.value == .undefined) {
                continue;
            }
            if ((expected.document.get(field.key) orelse BsonValue.undefined) == .undefined) {
                return false;
            }
        }
        return true;
    }
    return actual.eql(expected);
}
