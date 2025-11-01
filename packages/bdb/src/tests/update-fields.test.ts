import { updateFields } from '../lib/update-fields';

describe('updateFields', () => {
    test('should return original fields when no updates provided', () => {
        const fields = { name: 'John', age: 30 };
        const result = updateFields(fields, {});
        expect(result).toBe(fields); // Returns original when no updates.
    });

    test('should update simple fields', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { name: 'Jane' };
        const result = updateFields(fields, updates);
        expect(result).not.toBe(fields); // Returns new object.
        expect(result).toEqual({ name: 'Jane', age: 30 });
    });

    test('should add new fields', () => {
        const fields = { name: 'John' };
        const updates = { age: 30 };
        const result = updateFields(fields, updates);
        expect(result).toEqual({ name: 'John', age: 30 });
    });

    test('should delete fields set to undefined', () => {
        const fields = { name: 'John', age: 30 };
        const updates = { age: undefined };
        const result = updateFields(fields, updates);
        expect(result).toEqual({ name: 'John' });
        expect(result).not.toHaveProperty('age');
    });

    test('should recursively merge nested objects', () => {
        const fields = {
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC',
                zip: '10001'
            }
        };
        const updates = {
            address: {
                street: '456 Oak Ave'
            }
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'John',
            address: {
                street: '456 Oak Ave',
                city: 'NYC',
                zip: '10001'
            }
        });
    });

    test('should replace nested object when old value is not an object', () => {
        const fields = {
            name: 'John',
            address: 'old address'
        };
        const updates = {
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        });
    });

    test('should replace nested object when new value is not an object', () => {
        const fields = {
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        };
        const updates = {
            address: 'simple string'
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'John',
            address: 'simple string'
        });
    });

    test('should handle deeply nested objects', () => {
        const fields = {
            user: {
                name: 'John',
                profile: {
                    age: 30,
                    contact: {
                        email: 'john@example.com',
                        phone: '555-1234'
                    }
                }
            }
        };
        const updates = {
            user: {
                profile: {
                    contact: {
                        email: 'john.new@example.com'
                    }
                }
            }
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            user: {
                name: 'John',
                profile: {
                    age: 30,
                    contact: {
                        email: 'john.new@example.com',
                        phone: '555-1234'
                    }
                }
            }
        });
    });

    test('should delete nested fields', () => {
        const fields = {
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC',
                zip: '10001'
            }
        };
        const updates = {
            address: {
                zip: undefined
            }
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        });
        expect(result.address).not.toHaveProperty('zip');
    });

    test('should handle empty objects', () => {
        const fields = {};
        const updates = { name: 'John' };
        const result = updateFields(fields, updates);
        expect(result).toEqual({ name: 'John' });
    });

    test('should handle null oldFields', () => {
        const fields = null;
        const updates = { name: 'John' };
        const result = updateFields(fields, updates);
        expect(result).toEqual({ name: 'John' });
    });

    test('should handle undefined oldFields', () => {
        const fields = undefined;
        const updates = { name: 'John' };
        const result = updateFields(fields, updates);
        expect(result).toEqual({ name: 'John' });
    });

    test('should not treat arrays as nested objects', () => {
        const fields = {
            tags: ['a', 'b', 'c']
        };
        const updates = {
            tags: ['x', 'y']
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            tags: ['x', 'y']
        });
        // Arrays should be replaced, not merged
        expect(result.tags).toEqual(['x', 'y']);
    });

    test('should handle multiple updates at once', () => {
        const fields = {
            name: 'John',
            age: 30,
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        };
        const updates = {
            name: 'Jane',
            age: 31,
            address: {
                street: '456 Oak Ave'
            },
            email: 'jane@example.com'
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'Jane',
            age: 31,
            address: {
                street: '456 Oak Ave',
                city: 'NYC'
            },
            email: 'jane@example.com'
        });
    });

    test('should handle deleting entire nested object', () => {
        const fields = {
            name: 'John',
            address: {
                street: '123 Main St',
                city: 'NYC'
            }
        };
        const updates = {
            address: undefined
        };
        const result = updateFields(fields, updates);
        expect(result).toEqual({
            name: 'John'
        });
        expect(result).not.toHaveProperty('address');
    });
});
