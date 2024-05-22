import { visitRecords } from "../../lib/visit-records";

describe("visit records", () => {

    test("can visit zero records", async () => {
        const mockCollection: any = {
            listAll: async () => ({ records: [], next: undefined }),
        };
        const mockDatabase: any = {
            collection: jest.fn(() => mockCollection),
        };

        const callback = jest.fn();

        await visitRecords<any>(mockDatabase, "ABC", callback);

        expect(callback).toHaveBeenCalledTimes(0);
    });

    test("can visit multiple records", async () => {
        const mockCollection: any = {
            listAll: async () => ({ records: ["1", "2"], next: undefined }),
            getOne: async (recordId: string) => ({ id: recordId }),
        };
        const mockDatabase: any = {
            collection: jest.fn(() => mockCollection),
        };

        const callback = jest.fn();

        await visitRecords<any>(mockDatabase, "ABC", callback);

        expect(callback).toHaveBeenCalledTimes(2);
        expect(callback).toHaveBeenNthCalledWith(1, "1", { id: "1" });
        expect(callback).toHaveBeenNthCalledWith(2, "2", { id: "2" });        
    });

    test("can visit multiple pages of recoreds", async () => {            
        const mockCollection: any = {
            listAll: jest.fn()
                .mockReturnValueOnce({ records: ["1", "2"], next: "next" })
                .mockReturnValueOnce({ records: ["3"], next: undefined }),
            getOne: async (recordId: string) => ({ id: recordId }),
        };    
        const mockDatabase: any = {
            collection: jest.fn(() => mockCollection),
        };

        const callback = jest.fn();

        await visitRecords<any>(mockDatabase, "ABC", callback);

        expect(callback).toHaveBeenCalledTimes(3);
        expect(callback).toHaveBeenNthCalledWith(1, "1", { id: "1" });
        expect(callback).toHaveBeenNthCalledWith(2, "2", { id: "2" });
        expect(callback).toHaveBeenNthCalledWith(3, "3", { id: "3" });
    });
});