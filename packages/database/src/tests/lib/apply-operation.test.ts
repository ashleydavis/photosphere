import exp from "constants";
import { applyOperation, applyOperationToCollection, applyOperationToDb } from "../../lib/apply-operation";

describe("apply operation", () => {
    test("can set field", () => {
        const fields = {};
        applyOperation({ type: "set", fields: { name: "Alice" } }, fields);
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

describe("apply operation to collection", () => {
    test("can apply operation", async () => {
        const mockCollection: any = {
            getOne: async () => ({}),
            setOne: jest.fn(),
        };
        await applyOperationToCollection(mockCollection, {
            databaseName: "XYZ",
            collectionName: "ABC",
            recordId: "123",
            op: {
                type: "set",
                fields: {
                    name: "Alice"
                },
            }
        });
        expect(mockCollection.setOne).toHaveBeenCalledWith("123", { name: "Alice" });
    });

});

describe("apply operation to database", () => {
    test("can apply operation", async () => {
        const mockJournal: any = {
            setOne: jest.fn(),
        };
        const mockCollection: any = {
            getOne: async () => ({}),
            setOne: jest.fn(),
        };
        const mockDatabase: any = {
            collection(collectionName: string) {
                if (collectionName === "journal") {
                    return mockJournal;
                }

                if (collectionName === "ABC") {
                    return mockCollection;
                }

                throw new Error(`Unknown collection: ${collectionName}`);
            },
        };
        await applyOperationToDb(mockDatabase, {
            databaseName: "XYZ",
            collectionName: "ABC",
            recordId: "123",
            op: {
                type: "set",
                fields: {
                    name: "Alice"
                },
            }
        }, "some-client");

        expect(mockJournal.setOne).toHaveBeenCalledWith(expect.any(String), {
            clientId: "some-client",
            collectionName: "ABC",
            recordId: "123",
            op: {
                type: "set",
                fields: {
                    name: "Alice",
                },
            },            
            serverTime: expect.any(String),
        });
        expect(mockCollection.setOne).toHaveBeenCalledWith("123", { name: "Alice" });
    });
});