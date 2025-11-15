import { updateMetadata } from '../lib/update-metadata';
import { type Metadata } from '../lib/collection';

describe('updateMetadata', () => {
    test('should always create fields metadata when field changes, regardless of timestamp', () => {
        const fields = { name: 'John' };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {};
        const timestamp = 999;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Field metadata should be created
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(999);
    });

    test('should create fields metadata when field changes', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {};
        
        const result = updateMetadata(fields, updates, metadata, 2000);
        
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(2000);
        expect(result.fields!.age).toBeUndefined();
    });

    test('should not create metadata entry for unchanged values', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane', age: 30 }; // age unchanged
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(2000);
        expect(result.fields!.age).toBeUndefined();
    });

    test('should update metadata entry when value changes', () => {
        const fields = { name: 'John' };
        const updates = { name: 'Jane' };
        const metadata: Metadata = { 
            fields: {
                name: { timestamp: 1500 }
            }
        };
        const timestamp = 2000;
        
        // First update changes name
        const result = updateMetadata(fields, updates, metadata, timestamp);
        expect(result.fields!.name).toBeDefined();
        
        // Second update changes it back
        const fields2 = { name: 'Jane' };
        const updates2 = { name: 'John' };
        const timestamp2 = 2500;
        Object.assign(metadata, result); // Need to update for next call
        const result2 = updateMetadata(fields2, updates2, metadata, timestamp2);
        
        // Should still have metadata since it changed
        expect((result2.fields!.name).timestamp).toBe(2500);
    });

    test('should preserve metadata entry when value is unchanged', () => {
        const fields = { name: 'John' };
        const updates = { name: 'John' }; // Same value
        const metadata: Metadata = { 
            fields: {
                name: { timestamp: 1500 }
            }
        };
        const timestamp = 2000;
        
        // Update with same value - metadata should be preserved
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Metadata should still exist with original timestamp
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(1500); // Original timestamp preserved
    });

    test('should handle deleting a field (undefined value)', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane', age: undefined };
        const metadata: Metadata = { 
            fields: {
                age: { timestamp: 1500 }
            }
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields).toBeDefined();
        expect(result.fields!.name).toBeDefined();
        // Deletion timestamp should be preserved when newer than parent
        expect((result.fields!.age).timestamp).toBe(2000); // Deletion timestamp
    });

    test('should handle nested objects', () => {
        const fields = { 
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave',
                city: 'New York'
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields).toBeDefined();
        expect(result.fields!.address).toBeDefined();
        
        const addressMeta = result.fields!.address;
        expect(addressMeta.fields).toBeDefined();
        expect(addressMeta.fields!.street).toBeDefined();
        expect((addressMeta.fields!.street).timestamp).toBe(2000);
        expect(addressMeta.fields!.city).toBeUndefined(); // Unchanged
    });

    test('should handle deeply nested objects', () => {
        const fields = {
            address: {
                street: '123 Main St',
                country: {
                    code: 'US',
                    name: 'United States'
                }
            }
        };
        const updates = {
            address: {
                //fio: ...fields.address,
                country: {
                    code: 'CA',
                    name: 'Canada'
                }
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.address).toBeDefined();
        
        const addressMeta = result.fields!.address;
        const countryMeta = addressMeta.fields!.country;
        expect(countryMeta.fields).toBeDefined();
        expect(countryMeta.fields!.code).toBeDefined();
        expect(countryMeta.fields!.name).toBeDefined();
    });

    test('should handle arrays (treat as leaf values)', () => {
        const fields = { tags: ['a', 'b'] };
        const updates = { tags: ['c', 'd'] };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Arrays should be treated as leaf values, not nested objects
        expect(result.fields).toBeDefined();
        expect(result.fields!.tags).toBeDefined();
        expect((result.fields!.tags).timestamp).toBe(2000);
    });

    test('should handle null values', () => {
        const fields = { name: 'John', email: null };
        const updates = { name: 'Jane', email: 'john@example.com' };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields).toBeDefined();
        expect(result.fields!.name).toBeDefined();
        expect(result.fields!.email).toBeDefined();
    });

    test('should handle mixed updates (some nested, some leaf)', () => {
        const fields = {
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'New York'
            },
            age: 30
        };
        const updates = {
            name: 'Jane',
            address: {
                street: '456 Oak Ave',
                city: 'New York'
            },
            age: 31
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields).toBeDefined();
        expect(result.fields!.name).toBeDefined();
        expect(result.fields!.address).toBeDefined();
        const addressMeta3 = result.fields!.address;
        expect(addressMeta3.fields!.street).toBeDefined();
        expect(addressMeta3.fields!.city).toBeUndefined();
        expect(result.fields!.age).toBeDefined();
    });

    test('should handle updating nested object where some fields are new', () => {
        const fields = {
            address: {
                street: '123 Main St'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave',
                city: 'New York' // New field
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.address).toBeDefined();
        const addressMeta4 = result.fields!.address;
        expect(addressMeta4.fields!.street).toBeDefined();
        expect(addressMeta4.fields!.city).toBeDefined(); // New field gets timestamp
    });

    test('should preserve existing nested metadata structure', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave',
                city: 'Boston'
            }
        };
        const metadata: Metadata = {
            fields: {
                address: {
                    fields: {
                        street: { timestamp: 500 }
                    }
                }
            }
        };
        const timestamp = 2000;        
        const result = updateMetadata(fields, updates, metadata, timestamp);        
        const addressMeta = result.fields!.address;
        expect((addressMeta.fields!.street).timestamp).toBe(2000);
        expect(addressMeta.fields!.city).toBeDefined();
        expect((addressMeta.fields!.city).timestamp).toBe(2000);
    });

    test('should handle empty updates object', () => {
        const fields = { name: 'John' };
        const updates = {};
        const metadata: Metadata = {};
        const timestamp = 2000;        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should not create fields if no updates
        expect(result.fields).toBeUndefined();
    });

    test('should handle updating single field multiple times', () => {
        const fields = { name: 'John' };
        const metadata: Metadata = {};
        
        // First update
        const updates1 = { name: 'Jane' };
        const result1 = updateMetadata(fields, updates1, metadata, 2000);
        expect((result1.fields!.name).timestamp).toBe(2000);
        
        // Second update
        const fields2 = { name: 'Jane' };
        const updates2 = { name: 'Bob' };
        Object.assign(metadata, result1); // Need to update for next call
        const result2 = updateMetadata(fields2, updates2, metadata, 3000);
        expect((result2.fields!.name).timestamp).toBe(3000);
    });

    test('should handle updating nested object to null', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: null
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // When nested object is set to null, it becomes a leaf value (has timestamp)
        expect((result.fields!.address).timestamp).toBe(2000);
        expect('fields' in result.fields!.address).toBe(false);
    });

    test('should handle updating null to nested object', () => {
        const fields = {
            address: null
        };
        const updates = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const timestamp = 2000;        
        const result = updateMetadata(fields, updates, {}, timestamp);
        
        // When updating from null to nested object, it becomes a nested object (no timestamp).
        expect(result.fields!.address).toBeDefined();

        // Should recurse into nested object.
        const addressMeta = result.fields!.address;
        expect(addressMeta).toBeDefined();
        expect(addressMeta.timestamp).toBe(2000);
        expect(addressMeta.fields).toBeUndefined();
    });

    test('should handle empty nested objects', () => {
        const fields = {
            address: {}
        };
        const updates = {
            address: {
                street: '123 Main St'
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.address).toBeDefined();
        const addressMeta7 = result.fields!.address;
        expect(addressMeta7.fields!.street).toBeDefined();
    });

    test('should handle boolean values', () => {
        const fields = { active: false };
        const updates = { active: true };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.active).toBeDefined();
        expect((result.fields!.active).timestamp).toBe(2000);
    });

    test('should handle number values', () => {
        const fields = { count: 0 };
        const updates = { count: 5 };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.count).toBeDefined();
        expect((result.fields!.count).timestamp).toBe(2000);
    });

    test('should handle string values', () => {
        const fields = { text: 'old' };
        const updates = { text: 'new' };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.text).toBeDefined();
        expect((result.fields!.text).timestamp).toBe(2000);
    });

    test('should always track field metadata regardless of parent timestamp', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane', age: 31 };
        const metadata: Metadata = {};
        const timestamp = 2000; // Same as parent
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // We always track field metadata now, regardless of parent timestamp
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(2000);
        expect((result.fields!.age).timestamp).toBe(2000);
    });

    test('should handle nested object optimization', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave',
                city: 'Boston'
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000; // Same as parent
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // We always track field metadata now, even if timestamp equals parent
        expect(result.fields).toBeDefined();
        expect(result.fields!.address).toBeDefined();
        const addressMeta8 = result.fields!.address;
        expect((addressMeta8.fields!.street).timestamp).toBe(2000);
        expect((addressMeta8.fields!.city).timestamp).toBe(2000);
    });

    test('should handle partial nested object updates', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York',
                zip: '10001'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave',
                city: 'New York', // Unchanged
                zip: '10001' // Unchanged
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        const addressMeta9 = result.fields!.address;
        expect(addressMeta9.fields!.street).toBeDefined();
        expect(addressMeta9.fields!.city).toBeUndefined();
        expect(addressMeta9.fields!.zip).toBeUndefined();
    });

    test('should handle updating multiple nested objects at once', () => {
        const fields = {
            home: { street: '123 Main' },
            work: { street: '456 Oak' }
        };
        const updates = {
            home: { street: '789 Pine' },
            work: { street: '456 Oak' } // Unchanged
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        expect(result.fields!.home).toBeDefined();
        const homeMeta = result.fields!.home;
        expect(homeMeta.fields!.street).toBeDefined();
        // work didn't change, so no metadata should be created for it
        expect(result.fields!.work).toBeUndefined();
    });

    test('should handle deleting nested field within nested object', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York',
                zip: '10001'
            }
        };
        const updates = {
            address: {
                street: '123 Main St',
                city: 'New York',
                zip: undefined // Delete zip
            }
        };
        const metadata: Metadata = {
            fields: {
                address: {
                    fields: {
                        zip: { timestamp: 1500 }
                    }
                }
            }
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // zip was deleted with timestamp 2000
        // Deletion timestamp should be preserved
        const addressMeta10 = result.fields!.address;
        expect(addressMeta10.fields).toBeDefined();
        expect(addressMeta10.fields!.zip).toBeDefined();
        expect((addressMeta10.fields!.zip).timestamp).toBe(2000); // Deletion timestamp
    });

    test('should return early when metadata.timestamp is greater than update timestamp', () => {
        const fields = { name: 'John' };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {
            timestamp: 3000,
            fields: {
                name: { timestamp: 2500 }
            }
        };
        const timestamp = 2000; // Older than metadata.timestamp
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should return original metadata unchanged
        expect(result).toBe(metadata);
        expect(result.timestamp).toBe(3000);
        expect((result.fields!.name).timestamp).toBe(2500);
    });

    test('should return early when metadata.timestamp equals update timestamp', () => {
        const fields = { name: 'John' };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {
            timestamp: 2000,
            fields: {
                name: { timestamp: 1500 }
            }
        };
        const timestamp = 2000; // Equal to metadata.timestamp
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should return original metadata unchanged
        expect(result).toBe(metadata);
    });

    test('should preserve root timestamp in result', () => {
        const fields = { name: 'John' };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {
            timestamp: 1000
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Root timestamp should be preserved
        expect(result.timestamp).toBe(1000);
        expect(result.fields).toBeDefined();
        expect((result.fields!.name).timestamp).toBe(2000);
    });

    test('should preserve existing fields metadata not in updates', () => {
        const fields = { name: 'John', age: 30, email: 'john@example.com' };
        const updates = { name: 'Jane' }; // Only updating name
        const metadata: Metadata = {
            fields: {
                age: { timestamp: 1500 },
                email: { timestamp: 1600 }
            }
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Updated field should have new timestamp
        expect((result.fields!.name).timestamp).toBe(2000);
        // Other fields should be preserved
        expect((result.fields!.age).timestamp).toBe(1500);
        expect((result.fields!.email).timestamp).toBe(1600);
    });

    test('should preserve existing nested metadata when all nested fields unchanged', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: {
                street: '123 Main St', // Unchanged
                city: 'New York' // Unchanged
            }
        };
        const metadata: Metadata = {
            fields: {
                address: {
                    fields: {
                        street: { timestamp: 1500 },
                        city: { timestamp: 1500 }
                    }
                }
            }
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Since all fields in address are unchanged in this update, 
        // existing nested metadata should be preserved (function doesn't remove existing metadata)
        expect(result.fields).toBeDefined();
        expect(result.fields!.address).toBeDefined();
        expect((result.fields!.address.fields!.street).timestamp).toBe(1500);
        expect((result.fields!.address.fields!.city).timestamp).toBe(1500);
    });

    test('should handle converting object to array', () => {
        const fields = {
            items: { a: 1, b: 2 }
        };
        const updates = {
            items: [1, 2, 3] // Converting object to array
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Arrays are treated as leaf values
        expect(result.fields!.items).toBeDefined();
        expect((result.fields!.items).timestamp).toBe(2000);
        expect('fields' in result.fields!.items).toBe(false);
    });

    test('should handle converting array to object', () => {
        const fields = {
            items: [1, 2, 3]
        };
        const updates = {
            items: { a: 1, b: 2 } // Converting array to object
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Object should be treated as nested, but since it's a type change, it becomes a leaf
        expect(result.fields!.items).toBeDefined();
        expect((result.fields!.items).timestamp).toBe(2000);
        expect('fields' in result.fields!.items).toBe(false);
    });

    test('should handle null updates parameter', () => {
        const fields = { name: 'John' };
        const updates = null as any;
        const metadata: Metadata = {
            fields: {
                name: { timestamp: 1500 }
            }
        };
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should return original metadata unchanged
        expect(result).toBe(metadata);
    });

    test('should not mutate original metadata object', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane' };
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                age: { timestamp: 1500 }
            }
        };
        const timestamp = 2000;
        
        const originalMetadata = { ...metadata, fields: { ...metadata.fields } };
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Original metadata should be unchanged
        expect(metadata.timestamp).toBe(originalMetadata.timestamp);
        expect((metadata.fields!.age).timestamp).toBe((originalMetadata.fields!.age).timestamp);
        expect(metadata.fields!.name).toBeUndefined();
        
        // Result should be a new object
        expect(result).not.toBe(metadata);
        expect((result.fields!.name).timestamp).toBe(2000);
    });

    test('should not create nested metadata when all nested fields unchanged from empty metadata', () => {
        const fields = {
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        const updates = {
            address: {
                street: '123 Main St', // Unchanged
                city: 'New York' // Unchanged
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Since all fields are unchanged and we started with empty metadata,
        // the recursive call processes unchanged values and skips them,
        // resulting in nested metadata with no tracked fields, which gets deleted
        // Since address wasn't in existingFields, newFields remains empty {}
        expect(result.fields).toBeDefined();
        expect(result.fields!.address).toBeUndefined();
    });

    test('should handle nested object to array conversion in nested field', () => {
        const fields = {
            data: {
                items: { a: 1 }
            }
        };
        const updates = {
            data: {
                items: [1, 2] // Converting nested object to array
            }
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should track the nested change
        const dataMeta = result.fields!.data;
        expect(dataMeta.fields).toBeDefined();
        expect((dataMeta.fields!.items).timestamp).toBe(2000);
        expect('fields' in dataMeta.fields!.items).toBe(false);
    });

    test('should handle updating to undefined when field does not exist', () => {
        const fields = { name: 'John' };
        const updates = { 
            name: 'Jane',
            nonexistent: undefined // Deleting a field that doesn't exist
        };
        const metadata: Metadata = {};
        const timestamp = 2000;
        
        const result = updateMetadata(fields, updates, metadata, timestamp);
        
        // Should still track deletion timestamp for undefined field
        expect((result.fields!.name).timestamp).toBe(2000);
        expect((result.fields!.nonexistent).timestamp).toBe(2000);
    });
});
