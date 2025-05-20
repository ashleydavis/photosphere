"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.TestIndexeddb = TestIndexeddb;
const react_1 = __importStar(require("react"));
//
// Checks for equality between two arrays.
//
function arraysEqual(a, b) {
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
function TestIndexeddb() {
    (0, react_1.useEffect)(() => {
        let db = undefined;
        function testDb() {
            return __awaiter(this, void 0, void 0, function* () {
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
            });
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
        };
    }, []);
    return (react_1.default.createElement("div", null, "Test IndexedDB."));
}
