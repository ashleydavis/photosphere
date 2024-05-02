//
// Opens the database.
//
export function openDatabase(): Promise<IDBDatabase> {
    return new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("photosphere-test-1", 4);

        request.onupgradeneeded = event => { // This is called when the version field above is incremented.
            const db = (event.target as IDBOpenDBRequest).result;
            createObjectStores(db);
        };
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);
    });
}

//
// Creates object store only if they don't already exist.
//
async function createObjectStores(db: IDBDatabase) {
    if (!db.objectStoreNames.contains("thumb")) {
        db.createObjectStore("thumb", { keyPath: "_id" });
    }

    if (!db.objectStoreNames.contains("display")) {
        db.createObjectStore("display", { keyPath: "_id" });
    }

    if (!db.objectStoreNames.contains("asset")) {
        db.createObjectStore("asset", { keyPath: "_id" });
    }

    if (!db.objectStoreNames.contains("hashes")) {
        db.createObjectStore("hashes", { keyPath: "_id" });
    }

    if (!db.objectStoreNames.contains("metadata")) {
        db.createObjectStore("metadata", { keyPath: "_id" });
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
        const transaction = db.transaction(collectionName, "readonly");
        const store = transaction.objectStore(collectionName);
        const request = store.get(assetId);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
            const data = request.result;
            resolve(data ? data.data as IAssetData : undefined);
        };
    });
}

