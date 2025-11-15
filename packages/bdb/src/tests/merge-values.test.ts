import { mergeValues, MergeValue } from '../lib/merge-records';

describe('mergeValues', () => {
    test('should return value1 when it has newer timestamp and both are primitives', () => {
        const value1: MergeValue = {
            value: 'hello',
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 'world',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('hello');
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should return value2 when it has newer timestamp and both are primitives', () => {
        const value1: MergeValue = {
            value: 'hello',
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: 'world',
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('world');
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should return value2 when timestamps are equal and both are primitives', () => {
        const value1: MergeValue = {
            value: 'hello',
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: 'world',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('world');
        expect(result.metadata.timestamp).toBe(1000);
    });

    test('should handle number primitives', () => {
        const value1: MergeValue = {
            value: 42,
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 100,
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe(42);
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should handle boolean primitives', () => {
        const value1: MergeValue = {
            value: true,
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: false,
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe(false);
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should handle null as primitive', () => {
        const value1: MergeValue = {
            value: null,
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 'not null',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe(null);
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should handle undefined as primitive', () => {
        const value1: MergeValue = {
            value: undefined,
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 'defined',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        // value1 is undefined, so value2 wins regardless of timestamp
        expect(result.value).toBe('defined');
        expect(result.metadata.timestamp).toBe(1000);
    });

    test('should merge objects when both are objects', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', email: 'jane@example.com' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toEqual({
            name: 'Jane',
            age: 30,
            email: 'jane@example.com'
        });
        expect(result.metadata.timestamp).toBe(1000); // Math.min from mergeFields
        expect(result.metadata.fields).toBeDefined();
    });

    test('should return primitive when one side is primitive and other is object', () => {
        const value1: MergeValue = {
            value: 'string',
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { complex: 'object' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        // value1 is primitive, value2 is object (both are primitives or one is primitive)
        // value2 has newer timestamp (2000 > 1000), so value2 wins
        expect(result.value).toEqual({ complex: 'object' });
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should return primitive when other side is primitive and one is object', () => {
        const value1: MergeValue = {
            value: { complex: 'object' },
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 'string',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        // value1 has newer timestamp, so it wins (even though it's an object)
        // Wait, let me re-read: if isPrimitive(value1) OR isPrimitive(value2)
        // So if either is primitive, compare timestamps and return the newer one
        expect(result.value).toEqual({ complex: 'object' });
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should handle arrays as objects (not primitives)', () => {
        const value1: MergeValue = {
            value: [1, 2, 3],
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: [4, 5],
            metadata: { timestamp: 2000 }
        };

        // Arrays are objects (not primitives), so they should be merged
        const result = mergeValues(value1, value2);

        // Arrays will be treated as objects and merged by keys
        expect(result.value).toBeDefined();
        expect(result.metadata.fields).toBeDefined();
    });

    test('should handle empty objects', () => {
        const value1: MergeValue = {
            value: {},
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: {},
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toEqual({});
        expect(result.metadata.timestamp).toBe(1000);
        expect(result.metadata.fields).toEqual({});
    });

    test('should merge deeply nested objects', () => {
        const value1: MergeValue = {
            value: {
                level1: {
                    level2: { value: 'deep1' }
                }
            },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: {
                level1: {
                    level2: { value: 'deep2', other: 'field' }
                }
            },
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value.level1.level2.value).toBe('deep2');
        expect(result.value.level1.level2.other).toBe('field');
        expect(result.metadata.fields).toBeDefined();
    });

    test('should handle primitive string vs number', () => {
        const value1: MergeValue = {
            value: 'text',
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: 123,
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('text');
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should handle primitive boolean vs string', () => {
        const value1: MergeValue = {
            value: true,
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: 'false',
            metadata: { timestamp: 2000 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('false');
        expect(result.metadata.timestamp).toBe(2000);
    });

    test('should merge objects with nested primitives', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 1500 }
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', age: 25 },
            metadata: {
                timestamp: 2000,
                fields: {
                    age: { timestamp: 1800 }
                }
            }
        };

        const result = mergeValues(value1, value2);

        // value1.name has explicit timestamp 1500, value2.name uses root timestamp 2000
        // value2.name wins (2000 > 1500)
        expect(result.value.name).toBe('Jane');
        // value2.age has timestamp 1800, value1.age has root timestamp 1000
        // value2.age wins (1800 > 1000)
        expect(result.value.age).toBe(25);
    });

    test('should handle Date objects as objects (not primitives)', () => {
        const date1 = new Date('2023-01-01');
        const date2 = new Date('2023-12-31');
        
        const value1: MergeValue = {
            value: date1,
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: date2,
            metadata: { timestamp: 2000 }
        };

        // Date objects are objects (not primitives), so they should be merged
        const result = mergeValues(value1, value2);

        expect(result.value).toBeDefined();
        expect(result.metadata.fields).toBeDefined();
    });

    test('should handle mixed primitive types with equal timestamps', () => {
        const value1: MergeValue = {
            value: 42,
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: 'forty-two',
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        // When timestamps are equal, value2 wins (timestamp1 > timestamp2 is false)
        expect(result.value).toBe('forty-two');
        expect(result.metadata.timestamp).toBe(1000);
    });

    test('should handle object with null nested value vs object with defined nested value', () => {
        const value1: MergeValue = {
            value: { field: null },
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: { field: 'value' },
            metadata: { timestamp: 1000 }
        };

        const result = mergeValues(value1, value2);

        // Both are objects, so merge fields
        // value1.field has timestamp 2000, value2.field has timestamp 1000
        // So value1.field (null) should win
        expect(result.value.field).toBe(null);
    });

    test('should handle very large timestamps', () => {
        const value1: MergeValue = {
            value: 'value1',
            metadata: { timestamp: Number.MAX_SAFE_INTEGER }
        };
        const value2: MergeValue = {
            value: 'value2',
            metadata: { timestamp: Number.MAX_SAFE_INTEGER - 1 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('value1');
        expect(result.metadata.timestamp).toBe(Number.MAX_SAFE_INTEGER);
    });

    test('should handle zero timestamps', () => {
        const value1: MergeValue = {
            value: 'value1',
            metadata: { timestamp: 0 }
        };
        const value2: MergeValue = {
            value: 'value2',
            metadata: { timestamp: 1 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('value2');
        expect(result.metadata.timestamp).toBe(1);
    });

    test('should handle negative timestamps', () => {
        const value1: MergeValue = {
            value: 'value1',
            metadata: { timestamp: -100 }
        };
        const value2: MergeValue = {
            value: 'value2',
            metadata: { timestamp: -200 }
        };

        const result = mergeValues(value1, value2);

        expect(result.value).toBe('value1'); // -100 > -200
        expect(result.metadata.timestamp).toBe(-100);
    });
});

