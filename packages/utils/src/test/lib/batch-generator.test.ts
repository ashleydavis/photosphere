import { batchGenerator } from "../../lib/batch-generator";

//
// Helper to collect all batches from batchGenerator into an array.
//
async function collectBatches<T>(source: AsyncIterable<T>, batchSize: number): Promise<T[][]> {
    const batches: T[][] = [];
    for await (const batch of batchGenerator(source, batchSize)) {
        batches.push(batch);
    }
    return batches;
}

//
// Helper to create an async iterable from an array.
//
async function* fromArray<T>(items: T[]): AsyncGenerator<T> {
    for (const item of items) {
        yield item;
    }
}

describe("batchGenerator", () => {
    it("yields nothing for an empty source", async () => {
        const batches = await collectBatches(fromArray([]), 3);
        expect(batches).toEqual([]);
    });

    it("yields a single full batch when count equals batch size", async () => {
        const batches = await collectBatches(fromArray([1, 2, 3]), 3);
        expect(batches).toEqual([[1, 2, 3]]);
    });

    it("yields multiple full batches", async () => {
        const batches = await collectBatches(fromArray([1, 2, 3, 4, 5, 6]), 3);
        expect(batches).toEqual([[1, 2, 3], [4, 5, 6]]);
    });

    it("yields a partial final batch when count is not a multiple of batch size", async () => {
        const batches = await collectBatches(fromArray([1, 2, 3, 4, 5]), 3);
        expect(batches).toEqual([[1, 2, 3], [4, 5]]);
    });

    it("yields one batch per item when batch size is 1", async () => {
        const batches = await collectBatches(fromArray([1, 2, 3]), 1);
        expect(batches).toEqual([[1], [2], [3]]);
    });

    it("yields a single batch when batch size exceeds item count", async () => {
        const batches = await collectBatches(fromArray([1, 2, 3]), 100);
        expect(batches).toEqual([[1, 2, 3]]);
    });
});
