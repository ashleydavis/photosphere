import { applyOperation } from "../../lib/apply-operation";

describe("apply operation", () => {
    test("can set field", () => {
        const fields = {};
        applyOperation({ type: "set", fields: { name: "Alice" } }, fields);
        expect(fields).toEqual({ name: "Alice" });
    });

    test("setting a field leaves other fields in tact", () => {
        const fields = {
            A: 1,
            B: 2,
        };
        applyOperation({ type: "set", fields: { name: "Alice" } }, fields);
        expect(fields).toEqual({ 
            name: "Alice",
            A: 1,
            B: 2,
        });
    });

    test("setting a field to a bad value doesn't change the field", () => {
        const fields = {
            name: "Alice",
        };
        applyOperation({ type: "set", fields: { name: null } }, fields);
        expect(fields).toEqual({ name: "Alice" });

        applyOperation({ type: "set", fields: { name: undefined } }, fields);
        expect(fields).toEqual({ name: "Alice" });

        applyOperation({ type: "set", fields: { name: NaN } }, fields);
        expect(fields).toEqual({ name: "Alice" });
    });

    test("can push value on empty array", () => {
        const fields = {};
        applyOperation({ type: "push", field: "tags", value: "foo" }, fields);
        expect(fields).toEqual({ tags: ["foo"] });
    });

    test("can push value on existing array", () => {
        const fields = { tags: ["foo"] };
        applyOperation({ type: "push", field: "tags", value: "bar" }, fields);
        expect(fields).toEqual({ tags: ["foo", "bar"] });
    });

    test("pushing value more than once has no effect", () => {
        const fields = { tags: ["foo"] };
        applyOperation({ type: "push", field: "tags", value: "foo" }, fields);
        expect(fields).toEqual({ tags: ["foo"] });
    });

    test("can pull exiting value", () => {
        const fields = { tags: ["foo", "bar"] };
        applyOperation({ type: "pull", field: "tags", value: "foo" }, fields);
        expect(fields).toEqual({ tags: ["bar"] });
    });

    test("can pull non-existing value", () => {
        const fields = { tags: ["foo", "bar"] };
        applyOperation({ type: "pull", field: "tags", value: "baz" }, fields);
        expect(fields).toEqual({ tags: ["foo", "bar"] });
    });

    test("can pull value from empty array", () => {
        const fields = {};
        applyOperation({ type: "pull", field: "tags", value: "foo" }, fields);
        expect(fields).toEqual({ tags: [] });
    });
});

