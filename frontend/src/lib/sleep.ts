
//
// Sleeps for the specified millseconds.
//
//
export async function sleep(timeMS: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        setTimeout(() => resolve(), timeMS);
    });
}