//
// Consumes an async generator and yields its items in fixed-size batches.
// The final batch may be smaller than batchSize if the source is exhausted.
//
export async function* batchGenerator<T>(source: AsyncIterable<T>, batchSize: number): AsyncGenerator<T[]> {
    let batch: T[] = [];

    for await (const item of source) {
        batch.push(item);

        if (batch.length >= batchSize) {
            yield batch;
            batch = [];
        }
    }

    if (batch.length > 0) {
        yield batch;
    }
}
