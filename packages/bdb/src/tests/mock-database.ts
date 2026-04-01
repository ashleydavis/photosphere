import type { IBsonDatabase } from '../lib/database';
import type { IBsonCollection, IRecord } from '../lib/collection';
import { MockCollection, NoopMerkleRef } from './mock-collection';
import type { IMerkleRef } from '../lib/merkle-tree-ref';

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

    //
    // Stub commit — delegates to all mock collections.
    //
    async commit(): Promise<void> {
        for (const coll of this.collectionsMap.values()) {
            await coll.commit();
        }
    }

    //
    // Stub flush — no-op for mock.
    //
    flush(): void {
    }

    merkleTree(): IMerkleRef {
        return new NoopMerkleRef();
    }

    // Helper method for testing - get the underlying mock collection
    getMockCollection<T extends IRecord>(name: string): MockCollection<T> {
        return this.collectionsMap.get(name) as MockCollection<T>;
    }
}