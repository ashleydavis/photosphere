import { getJournal } from "../../lib/get-journal";

describe("get journal", () => {

    test("can get empty journal", async () => {
        const mockJournalCollection: any = {
            listAll: async () => {
                return {
                    records: [],
                    next: undefined,
                };
            },
        };
        const mockDatabase: any = {
            collection: () => mockJournalCollection,
        };
        const clientId = "client1";
        const lastUpdateId = undefined;
        

        const result = await getJournal(mockDatabase, clientId, lastUpdateId);
        expect(result.ops).toEqual([]);
        expect(result.latestUpdateId).toBeUndefined();
    });

    test("can get journal with records", async () => {
        const records = [
            {
                clientId: "client-2",
                recordId: "05",
                collectionName: "collection-1",
                op: {},
            },
            {
                clientId: "client-2",
                recordId: "06",
                collectionName: "collection-1",
                op: {},
            },
        ]
        const mockJournalCollection: any = {
            getOne: async (id: string) => {
                return records.find(r => r.recordId === id);
            },
            listAll: async () => {
                return {
                    records: records.map(r => r.recordId),
                    next: undefined,
                };
            },
        };
        const mockDatabase: any = {
            collection: () => mockJournalCollection,
        };

        const result = await getJournal(mockDatabase, "client-1", undefined);
        expect(result.ops).toEqual([
            {
                collectionName: "collection-1",
                recordId: "06",
                op: {},
            },
            {
                collectionName: "collection-1",
                recordId: "05",
                op: {},
            },        
        ]);
        expect(result.latestUpdateId).toBe("05");
    });

    test("can get journal with multiple pages", async () => {
        const record1 = {
            clientId: "client-2",
            recordId: "05",
            collectionName: "collection-1",
            op: {},
        };
        const record2 = {
            clientId: "client-2",
            recordId: "06",
            collectionName: "collection-1",
            op: {},
        };
        const mockJournalCollection: any = {
            getOne: async (id: string) => {
                if (id === "05") {
                    return record1;
                } 
                else if (id === "06") {
                    return record2;
                }
                
                return undefined;
            },
            listAll: jest.fn()
                .mockImplementationOnce(async () => ({
                    records: [ record1.recordId ],
                    next: "next-page",
                }))
                .mockImplementationOnce(async () => ({
                    records: [ record2.recordId ],
                    next: undefined,
                })),
        };
        const mockDatabase: any = {
            collection: () => mockJournalCollection,
        };

        const result = await getJournal(mockDatabase, "client-1", undefined);
        expect(result.ops).toEqual([
            {
                collectionName: "collection-1",
                recordId: "06",
                op: {},
            },
            {
                collectionName: "collection-1",
                recordId: "05",
                op: {},
            },        
        ]);
        expect(result.latestUpdateId).toBe("05");
    });

    test("records from requesting client are filtered out", async () => {
        const records = [
            {
                clientId: "client-2",
                recordId: "02",
                collectionName: "collection-1",
                op: {},
            },
            {
                clientId: "client-1",
                recordId: "07",
                collectionName: "collection-1",
                op: {},
            },
            {
                clientId: "client-3",
                recordId: "08",
                collectionName: "collection-1",
                op: {},
            },
        ]
        const mockJournalCollection: any = {
            getOne: async (id: string) => {
                return records.find(r => r.recordId === id);
            },
            listAll: async () => {
                return {
                    records: records.map(r => r.recordId),
                    next: undefined,
                };
            },
        };
        const mockDatabase: any = {
            collection: () => mockJournalCollection,
        };

        const result = await getJournal(mockDatabase, "client-1", undefined);
        expect(result.ops).toEqual([
            {
                collectionName: "collection-1",
                recordId: "08",
                op: {},
            },
            {
                collectionName: "collection-1",
                recordId: "02",
                op: {},
            },
        ]);
        expect(result.latestUpdateId).toBe("02");
    });
});