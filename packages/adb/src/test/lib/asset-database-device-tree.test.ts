import { AssetDatabase } from '../../lib/asset-database';
import { MockStorage } from "storage/src/tests/mock-storage";
import { TestUuidGenerator } from 'node-utils';
import { generateDeviceId } from 'node-utils';
import { pathJoin } from 'storage';

describe('Asset Database Device-Specific Tree', () => {
    
    test('should save and load tree.dat from device-specific location', async () => {
        const assetStorage = new MockStorage();
        const metadataStorage = new MockStorage();
        const uuidGenerator = new TestUuidGenerator();
        
        // Create and save a database
        const database = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await database.create();
        await database.save();
        
        // Verify tree.dat was saved to device-specific location
        const deviceId = await generateDeviceId();
        const deviceTreePath = pathJoin("devices", deviceId, "tree.dat");
        
        expect(await metadataStorage.fileExists(deviceTreePath)).toBe(true);
        expect(await metadataStorage.fileExists("tree.dat")).toBe(false);
        
        // Create a new database instance and load from device-specific location
        const database2 = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await database2.load();
        
        // Should have loaded successfully
        const merkleTree = database2.getMerkleTree();
        expect(merkleTree).toBeDefined();
        expect(merkleTree.metadata.id).toBe(database.getMerkleTree().metadata.id);
    });
    
    test('should fall back to old tree.dat location if device-specific does not exist', async () => {
        const assetStorage = new MockStorage();
        const metadataStorage = new MockStorage();
        const uuidGenerator = new TestUuidGenerator();
        
        // Create database and save using the old saveTree method to simulate legacy database
        const database = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await database.create();
        
        // Manually save to old location using the saveTree function
        const { saveTree } = await import('../../lib/merkle-tree');
        await saveTree("tree.dat", database.getMerkleTree(), metadataStorage);
        
        // Verify old location exists and new location doesn't
        expect(await metadataStorage.fileExists("tree.dat")).toBe(true);
        
        const deviceId = await generateDeviceId();
        const deviceTreePath = pathJoin("devices", deviceId, "tree.dat");
        expect(await metadataStorage.fileExists(deviceTreePath)).toBe(false);
        
        // Create new database instance and load - should fall back to old location
        const database2 = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await database2.load();
        
        // Should have loaded successfully from old location
        const loadedTree = database2.getMerkleTree();
        expect(loadedTree).toBeDefined();
        expect(loadedTree.metadata.id).toBe(database.getMerkleTree().metadata.id);
    });
    
    test('should prefer device-specific location over old location', async () => {
        const assetStorage = new MockStorage();
        const metadataStorage = new MockStorage();
        const uuidGenerator = new TestUuidGenerator();
        
        // Create two different databases
        const oldDatabase = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await oldDatabase.create();
        const oldTreeId = oldDatabase.getMerkleTree().metadata.id;
        
        const newDatabase = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await newDatabase.create();
        const newTreeId = newDatabase.getMerkleTree().metadata.id;
        
        // Save old database to old location
        const { saveTree } = await import('../../lib/merkle-tree');
        await saveTree("tree.dat", oldDatabase.getMerkleTree(), metadataStorage);
        
        // Save new database to device-specific location
        const deviceId = await generateDeviceId();
        const deviceTreePath = pathJoin("devices", deviceId, "tree.dat");
        await saveTree(deviceTreePath, newDatabase.getMerkleTree(), metadataStorage);
        
        // Load should prefer device-specific location
        const database = new AssetDatabase(assetStorage, metadataStorage, uuidGenerator);
        await database.load();
        
        const merkleTree = database.getMerkleTree();
        expect(merkleTree.metadata.id).toBe(newTreeId); // Should load from device-specific location
    });
});