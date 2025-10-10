import { IBsonDatabase } from '../lib/bson-database/database';
import { IBsonCollection, IRecord } from '../lib/bson-database/collection';
import { MockCollection } from './mock-collection';

// Mock BsonDatabase for testing
export class MockDatabase implements IBsonDatabase {
    private collectionsMap: Map<string, MockCollection<any>> = new Map();

    collection<T extends IRecord>(name: string): IBsonCollection<T> {
        if (!this.collectionsMap.has(name)) {
            this.collectionsMap.set(name, new MockCollection<T>());
        }
        return this.collectionsMap.get(name)! as IBsonCollection<T>;
    }

    async collections(): Promise<string[]> {
        return Array.from(this.collectionsMap.keys());
    }

    // Helper method for testing - get the underlying mock collection
    getMockCollection<T extends IRecord>(name: string): MockCollection<T> {
        return this.collectionsMap.get(name) as MockCollection<T>;
    }
}