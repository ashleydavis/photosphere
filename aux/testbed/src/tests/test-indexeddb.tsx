import React, { useEffect } from "react";
import { indexeddb, PersistentQueue } from "user-interface";

//
// Checks for equality between two arrays.
//
function arraysEqual<T>(a: T[], b: T[]): boolean {
    if (a.length !== b.length) {
        return false;
    }

    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) {
            return false;
        }
    }

    return true;
}

export function TestIndexeddb() {

    useEffect(() => {

        let db: IDBDatabase | undefined = undefined;

        
        async function testDb() {

            // await indexeddb.deleteDatabase("photosphere-test-db");
            
            // db = await indexeddb.openDatabase("photosphere-test-db", 1, [
            //     { name: "test-collection" }
            // ]);

            // //
            // // Getting a non-existent record returns undefined.
            // //
            // const nonExistentRecord = await indexeddb.getRecord<any>(db, "test-collection", "non-existent-id");
            // if (nonExistentRecord !== undefined) {
            //     throw new Error("Expected non-existent record to return undefined.");
            // }
            // else {
            //     console.log("Non-existing record returns undefined.");
            // }

            // const testRecords = [
            //     { _id: "02", name: "test-2" },
                                
            //     //
            //     // This record is considered the oldest because the ids are 
            //     // in reverse chronological order.
            //     //
            //     { _id: "03", name: "test-3" }, 
                
            //     { _id: "01", name: "test-1" },
            // ]

            // for (const testRecord of testRecords) {
            //     await indexeddb.storeRecord<any>(db, "test-collection", testRecord);
            // }

            // //
            // // Can get least recent record.
            // //
            // const leastRecentRecord = await indexeddb.getLeastRecentRecord<any>(db, "test-collection");
            // console.log(`Load least recent record:`);
            // console.log(JSON.stringify(leastRecentRecord));

            // if (!leastRecentRecord || leastRecentRecord[0] !== "03") {
            //     throw new Error("Expected 03 to be the least recent record.");
            // }

            // //
            // // Can get all records in the correct order.
            // //
            // const allRecords = await indexeddb.getAllRecords<any>(db, "test-collection");
            // const allRecordIds = allRecords.map(record => record._id);
            // if (!arraysEqual(allRecordIds, ["01", "02", "03"])) {
            //     throw new Error("Expected all records to be in ascending order.");
            // }

            // await indexeddb.deleteDatabase("photosphere-queue-test");

            // //
            // // Can queue.
            // // 
            // const databases = new IndexeddbDatabases({
            //     "photosphere-queue-test": {
            //         collections: [ 
            //             { name: "test-queue" }
            //         ],
            //         versionNumber: 1,
            //     },
            //     collection: {
            //         collections: [
            //             { name: "thumb" },
            //             { name: "display" },
            //             { name: "asset" },
            //             { name: "metadata" },
            //         ],
            //         versionNumber: 1,
            //     },            
            // }, "collection");
            // const queue = new PersistentQueue<any>(databases.database("photosphere-queue-test"), "test-queue");
            // await queue.add({ test: "B" });
            // await queue.add({ test: "Z" });
            // await queue.add({ test: "A" });
            // const record1 = await queue.getNext();
            // if (record1 && record1.test !== "B") {
            //     throw new Error(`Expected B to be the first record. Got ${JSON.stringify(record1)}`);
            // }
            // await queue.removeNext();
            // const record2 = await queue.getNext();
            // if (record2 && record2.test !== "Z") {
            //     throw new Error(`Expected Z to be the second record. Got ${JSON.stringify(record2)}`);
            // }
            // await queue.removeNext();
            // const record3 = await queue.getNext();
            // if (record3 && record3.test !== "A") {
            //     throw new Error(`Expected A to be the third record. Got ${JSON.stringify(record3)}`);
            // }
            // await queue.removeNext();
            // const undefinedFinalRecord = await queue.getNext();
            // if (undefinedFinalRecord !== undefined) {
            //     throw new Error("Expected no more records.");
            // }

            // console.log(`!! All recoreds in test collection:`);
            // const metadataCollection = databases.database("test-collection").collection("metadata");
            // const records = await metadataCollection.getAll();
            // console.log(records);

            // await databases.shutdown();
        }

        testDb()
            .catch(err => {
                console.error(err);
            });

        return () => {
            if (db) {
                db.close();
                db = undefined;
            }
        }
    }, []);

    return (
        <div>
            Test IndexedDB.
        </div>
    );
}