//
// Opens the database.
//
export function openDatabase(databaseName: string, versionNumber: number, collectionNames: string[]): Promise<IDBDatabase> {
    return new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open(databaseName, versionNumber);

        request.onupgradeneeded = event => { // This is called when the version field above is incremented.
            const db = (event.target as IDBOpenDBRequest).result;
            createObjectStores(db, collectionNames);
        };
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);
    });
}

//
// Creates object store only if they don't already exist.
//
function createObjectStores(db: IDBDatabase, collectionNames: string[]) {
    for (const collectionName of collectionNames) {
        if (!db.objectStoreNames.contains(collectionName)) {
            db.createObjectStore(collectionName);
        }
    }
}

//
// Stores a record in the database.
//
export function storeRecord<RecordT>(db: IDBDatabase, collectionName: string, recordId: string, record: RecordT): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readwrite');
        const store = transaction.objectStore(collectionName);
        const request = store.put(record, recordId);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

//
// Gets a record from the database.
//
export function getRecord<RecordT>(db: IDBDatabase, collectionName: string, recordId: string): Promise<RecordT | undefined> {
    return new Promise<RecordT>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readonly');
        const store = transaction.objectStore(collectionName);
        const request = store.get(recordId);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);
    });
}

//
// Gets the least recent record from the database.
//
export function getLeastRecentRecord<RecordT>(db: IDBDatabase, collectionName: string): Promise<RecordT | undefined> {  
    return new Promise<RecordT | undefined>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readonly');
        const store = transaction.objectStore(collectionName);
        const request = store.openCursor(null, 'prev');
        request.onerror = () => reject(request.error);
        request.onsuccess = event => {
            const cursor = (event.target as IDBRequest<IDBCursorWithValue>).result;
            if (cursor) {
                resolve(cursor.value);
            } 
            else {
                resolve(undefined);
            }
        };
    });
}

//
// Gets all record keys from the database.
//
export function getAllKeys(db: IDBDatabase, collectionName: string): Promise<string[]> {
    return new Promise<string[]>((resolve, reject) => {
        const transaction = db.transaction([collectionName], "readonly");
        const store = transaction.objectStore(collectionName);
        const allRecordsRequest = store.getAllKeys(); 
        allRecordsRequest.onsuccess = () => resolve(Array.from(allRecordsRequest.result as string[]));
        allRecordsRequest.onerror = () => reject(allRecordsRequest.error);
    });
}

//
// Gets all records from the database.
//
export function getAllRecords<RecordT>(db: IDBDatabase, collectionName: string): Promise<RecordT[]> {
    return new Promise<RecordT[]>((resolve, reject) => {
        const transaction = db.transaction([collectionName], "readonly");
        const store = transaction.objectStore(collectionName);
        const allRecordsRequest = store.getAll(); 
        allRecordsRequest.onsuccess = () => resolve(allRecordsRequest.result);
        allRecordsRequest.onerror = () => reject(allRecordsRequest.error);
    });
}

//
// Deletes a record.
//
export function deleteRecord(db: IDBDatabase, collectionName: string, recordId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readwrite');
        const store = transaction.objectStore(collectionName);
        const request = store.delete(recordId);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

//
// Gets the number of records in the collection.
//
export function getNumRecords(db: IDBDatabase, collectionName: string): Promise<number> {
    return new Promise<number>((resolve, reject) => {
        const transaction = db.transaction([collectionName], 'readonly');
        const store = transaction.objectStore(collectionName);
        const request = store.count();
        request.onsuccess = () => {
            resolve(request.result);
        };
        request.onerror = () => reject(request.error);
    });
}

//
// Deletes the database.
//
export function deleteDatabase(databaseName: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const request = indexedDB.deleteDatabase(databaseName);
        request.onsuccess = () => resolve();
        request.onerror = () => reject(request.error);
        request.onblocked = () => reject(new Error("Database deletion is blocked"));
    });
}