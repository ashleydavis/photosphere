import React, { useEffect } from "react";
import { indexeddb } from "database";

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

            await indexeddb.deleteDatabase("photosphere-test-db");
            
            db = await indexeddb.openDatabase("photosphere-test-db", 1, [
                "test-collection",
            ]);

            //
            // Getting a non-existent record returns undefined.
            //
            const nonExistentRecord = await indexeddb.getRecord<any>(db, "test-collection", "non-existent-id");
            if (nonExistentRecord !== undefined) {
                throw new Error("Expected non-existent record to return undefined.");
            }
            else {
                console.log("Non-existing record returns undefined.");
            }

            const testRecords = [
                { _id: "02", name: "test-2" },
                                
                //
                // This record is considered the oldest because the ids are 
                // in reverse chronological order.
                //
                { _id: "03", name: "test-3" }, 
                
                { _id: "01", name: "test-1" },
            ]

            for (const testRecord of testRecords) {
                await indexeddb.storeRecord<any>(db, "test-collection", testRecord);
            }

            //
            // Can get least recent record.
            //
            const leastRecentRecord = await indexeddb.getLeastRecentRecord<any>(db, "test-collection");
            console.log(`Load least recent record:`);
            console.log(JSON.stringify(leastRecentRecord));

            if (!leastRecentRecord || leastRecentRecord._id !== "03") {
                throw new Error("Expected 03 to be the least recent record.");
            }

            //
            // Can get all records in the correct order.
            //
            const allRecords = await indexeddb.getAllRecords<any>(db, "test-collection");
            const allRecordIds = allRecords.map(record => record._id);
            if (!arraysEqual(allRecordIds, ["01", "02", "03"])) {
                throw new Error("Expected all records to be in ascending order.");
            }
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