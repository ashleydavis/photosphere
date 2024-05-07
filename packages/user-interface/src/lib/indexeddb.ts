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
            db.createObjectStore(collectionName, { keyPath: "_id" });
        }
    }
}

//
// Stores a record in the database.
//
export function storeRecord<RecordT>(db: IDBDatabase, collectionName: string, record: RecordT): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readwrite');
        const store = transaction.objectStore(collectionName);
        const request = store.put(record);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

//
// Gets a record from the database.
//
export function getRecord<RecordT>(db: IDBDatabase, collectionName: string, assetId: string): Promise<RecordT> {
    return new Promise<RecordT>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readonly');
        const store = transaction.objectStore(collectionName);
        const request = store.get(assetId);
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
export function deleteRecord(db: IDBDatabase, collectionName: string, assetId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(collectionName, 'readwrite');
        const store = transaction.objectStore(collectionName);
        const request = store.delete(assetId);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}


//
// Specifies the data for an asset.
// 
export interface IAssetData {
    //
    // The content type of the asset.
    //
    contentType: string;

    //
    // The blob containing the data for the asset.
    //
    data: Blob;
}

//
// Stores an asset in the database.
//
export function storeAsset(db: IDBDatabase, collectionName: string, assetId: string, assetData: IAssetData): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const tx = db.transaction(collectionName, "readwrite");
        const store = tx.objectStore(collectionName);
        const request = store.put({ _id: assetId, data: assetData });
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

//
// Gets an asset from the database.
//
export function getAsset(db: IDBDatabase, collectionName: string, assetId: string): Promise<IAssetData | undefined> {
    return new Promise((resolve, reject) => {
        try {
            const transaction = db.transaction(collectionName, "readonly");
            const store = transaction.objectStore(collectionName);
            const request = store.get(assetId);
            request.onerror = () => {
                console.error(`Failed to get asset ${assetId} from ${collectionName}`);
                reject(request.error);
            };
            request.onsuccess = () => {
                const data = request.result;
                resolve(data ? data.data as IAssetData : undefined);
            };
        }
        catch (err) {
            console.error(`Failed to get asset ${assetId} from ${collectionName}`);
            console.error(err);
            reject(err);
        }
    });
}

