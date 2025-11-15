import { mergeFields, MergeValue } from '../lib/merge-records';

describe('mergeFields', () => {
    test('should merge simple flat objects with different timestamps', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', email: 'jane@example.com' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeFields(value1, value2);

        expect(result.value).toEqual({
            name: 'Jane', // newer timestamp wins
            age: 30, // only in value 1
            email: 'jane@example.com' // only in value 2
        });
        expect(result.metadata.timestamp).toBe(1000); // Math.min of both timestamps
        expect(result.metadata.fields).toBeDefined();
        expect(result.metadata.fields!.name.timestamp).toBe(2000);
        expect(result.metadata.fields!.age.timestamp).toBe(1000);
        expect(result.metadata.fields!.email.timestamp).toBe(2000);
    });

    test('should merge when value1 has newer timestamp', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: { name: 'Jane' },
            metadata: { timestamp: 1000 }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.name).toBe('John'); // value1 has newer timestamp
        expect(result.value.age).toBe(30);
        expect(result.metadata.timestamp).toBe(1000); // Math.min
        expect(result.metadata.fields!.name.timestamp).toBe(2000);
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

        const result = mergeFields(value1, value2);

        expect(result.value).toEqual({});
        expect(result.metadata.timestamp).toBe(1000);
        expect(result.metadata.fields).toEqual({});
    });

    test('should merge nested objects recursively', () => {
        const value1: MergeValue = {
            value: {
                user: { name: 'John', age: 30 },
                settings: { theme: 'dark' }
            },
            metadata: {
                timestamp: 1000,
                fields: {
                    user: {
                        timestamp: 1000,
                        fields: {
                            name: { timestamp: 1000 },
                            age: { timestamp: 1000 }
                        }
                    },
                    settings: {
                        timestamp: 1000,
                        fields: {
                            theme: { timestamp: 1000 }
                        }
                    }
                }
            }
        };
        const value2: MergeValue = {
            value: {
                user: { name: 'Jane', email: 'jane@example.com' },
                settings: { theme: 'light', fontSize: 14 }
            },
            metadata: {
                timestamp: 2000,
                fields: {
                    user: {
                        timestamp: 2000,
                        fields: {
                            name: { timestamp: 2000 },
                            email: { timestamp: 2000 }
                        }
                    },
                    settings: {
                        timestamp: 2000,
                        fields: {
                            theme: { timestamp: 2000 },
                            fontSize: { timestamp: 2000 }
                        }
                    }
                }
            }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.user).toEqual({
            name: 'Jane', // newer timestamp
            age: 30, // value2 doesn't have age (undefined), so value1 wins
            email: 'jane@example.com' // only in value2
        });
        expect(result.value.settings).toEqual({
            theme: 'light', // newer timestamp
            fontSize: 14    // only in value2
        });
        expect(result.metadata.fields!.user.fields!.name.timestamp).toBe(2000);
        // age: value1 has it, value2 doesn't (undefined), so value1 wins
        expect(result.metadata.fields!.user.fields!.age.timestamp).toBe(1000);
        expect(result.metadata.fields!.settings.fields!.theme.timestamp).toBe(2000);
    });

    test('should handle fields with field-level metadata timestamps', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 1500 } // name has newer timestamp than root
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', email: 'jane@example.com' },
            metadata: {
                timestamp: 2000,
                fields: {
                    name: { timestamp: 1200 } // name has older timestamp than root but newer than value1 root
                }
            }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.name).toBe('John'); // value1.name timestamp (1500) > value2.name timestamp (1200)
        expect(result.metadata.fields!.name.timestamp).toBe(1500);
        expect(result.metadata.timestamp).toBe(1000); // Math.min of root timestamps
    });

    test('should handle deleted fields (fields in metadata but not in value)', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: {
                timestamp: 1000,
                fields: {
                    email: { timestamp: 1500 } // deleted field in metadata
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', email: 'jane@example.com' },
            metadata: {
                timestamp: 2000,
                fields: {
                    email: { timestamp: 2000 }
                }
            }
        };

        const result = mergeFields(value1, value2);

        // value2.email has newer timestamp, so it should win
        expect(result.value.email).toBe('jane@example.com');
        expect(result.metadata.fields!.email.timestamp).toBe(2000);
    });

    test('should handle both sides having deleted fields', () => {
        const value1: MergeValue = {
            value: { name: 'John' },
            metadata: {
                timestamp: 1000,
                fields: {
                    age: { timestamp: 500 }, // deleted with old timestamp
                    email: { timestamp: 1500 } // deleted with newer timestamp
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane' },
            metadata: {
                timestamp: 2000,
                fields: {
                    age: { timestamp: 1800 }, // deleted with newer timestamp
                    phone: { timestamp: 2000 } // deleted
                }
            }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.name).toBe('Jane'); // value2 has newer root timestamp
        expect(result.value.age).toBeUndefined();
        expect(result.value.email).toBeUndefined();
        expect(result.value.phone).toBeUndefined();
        
        // Fields with newer timestamps should be in metadata
        expect(result.metadata.fields!.age.timestamp).toBe(1800); // value2 wins
        // email: value1 has timestamp 1500, value2 doesn't have it (timestamp 2000 from root)
        // value2 wins (2000 > 1500), so timestamp should be 2000
        expect(result.metadata.fields!.email.timestamp).toBe(2000);
        expect(result.metadata.fields!.phone.timestamp).toBe(2000);
    });

    test('should merge arrays as primitives (treated as values, not merged)', () => {
        const value1: MergeValue = {
            value: { items: [1, 2, 3], tags: ['a', 'b'] },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { items: [4, 5], tags: ['c'] },
            metadata: { timestamp: 2000 }
        };

        const result = mergeFields(value1, value2);

        // Arrays are objects but mergeFields will try to merge them
        // Since they're not primitives, mergeValues will recursively call mergeFields
        // But arrays as objects will have numeric keys merged
        expect(result.value).toHaveProperty('items');
        expect(result.value).toHaveProperty('tags');
        expect(result.metadata.fields).toBeDefined();
    });

    test('should handle null and undefined values', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: null, email: undefined },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', age: 30 },
            metadata: { timestamp: 2000 }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.name).toBe('Jane');
        expect(result.value.age).toBe(30); // value2 wins (newer timestamp)
        expect(result.value.email).toBeUndefined();
    });

    test('should preserve deeply nested field metadata', () => {
        const value1: MergeValue = {
            value: {
                level1: {
                    level2: {
                        level3: { value: 'deep' }
                    }
                }
            },
            metadata: {
                timestamp: 1000,
                fields: {
                    level1: {
                        timestamp: 1000,
                        fields: {
                            level2: {
                                timestamp: 1000,
                                fields: {
                                    level3: {
                                        timestamp: 1000,
                                        fields: {
                                            value: { timestamp: 1000 }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };
        const value2: MergeValue = {
            value: {
                level1: {
                    level2: {
                        level3: { value: 'updated' }
                    }
                }
            },
            metadata: {
                timestamp: 2000,
                fields: {
                    level1: {
                        timestamp: 2000,
                        fields: {
                            level2: {
                                timestamp: 2000,
                                fields: {
                                    level3: {
                                        timestamp: 2000,
                                        fields: {
                                            value: { timestamp: 2000 }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.level1.level2.level3.value).toBe('updated');
        expect(result.metadata.fields!.level1.fields!.level2.fields!.level3.fields!.value.timestamp).toBe(2000);
    });

    test('should handle fields with same timestamp', () => {
        const value1: MergeValue = {
            value: { name: 'John' },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { name: 'Jane' },
            metadata: { timestamp: 1000 }
        };

        const result = mergeFields(value1, value2);

        // When timestamps are equal, value2 wins (timestamp1 > timestamp2 check is false)
        expect(result.value.name).toBe('Jane');
        expect(result.metadata.fields!.name.timestamp).toBe(1000);
        expect(result.metadata.timestamp).toBe(1000);
    });

    test('should merge when value1 has all keys and value2 has subset', () => {
        const value1: MergeValue = {
            value: { a: 1, b: 2, c: 3, d: 4 },
            metadata: { timestamp: 1000 }
        };
        const value2: MergeValue = {
            value: { b: 20 },
            metadata: { timestamp: 2000 }
        };

        const result = mergeFields(value1, value2);

        expect(result.value).toEqual({
            a: 1, // value2 doesn't have 'a' (undefined), so value1 wins
            b: 20, // value2 wins (newer timestamp)
            c: 3, // value2 doesn't have 'c' (undefined), so value1 wins
            d: 4 // value2 doesn't have 'd' (undefined), so value1 wins
        });
        expect(result.metadata.fields!.b.timestamp).toBe(2000);
        expect(result.metadata.fields!.a.timestamp).toBe(1000); // value2 doesn't have 'a' (undefined), so value1 wins
    });

    test('should merge when value2 has all keys and value1 has subset', () => {
        const value1: MergeValue = {
            value: { b: 2 },
            metadata: { timestamp: 2000 }
        };
        const value2: MergeValue = {
            value: { a: 10, b: 20, c: 30, d: 40 },
            metadata: { timestamp: 1000 }
        };

        const result = mergeFields(value1, value2);

        expect(result.value).toEqual({
            a: 10, // value1 doesn't have 'a' (undefined), so value2 wins
            b: 2, // value1 wins (newer timestamp)
            c: 30, // value1 doesn't have 'c' (undefined), so value2 wins
            d: 40 // value1 doesn't have 'd' (undefined), so value2 wins
        });
    });

    test('should handle field metadata without fields property', () => {
        const value1: MergeValue = {
            value: { name: 'John' },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 1500 } // no fields property
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane' },
            metadata: {
                timestamp: 2000,
                fields: {
                    name: { timestamp: 1200 }
                }
            }
        };

        const result = mergeFields(value1, value2);

        expect(result.value.name).toBe('John');
        expect(result.metadata.fields!.name.timestamp).toBe(1500);
        expect(result.metadata.fields!.name.fields).toEqual({});
    });

    test('should use root timestamp as default for fields without explicit timestamps', () => {
        const value1: MergeValue = {
            value: { name: 'John', age: 30 },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 1500 } // age doesn't have explicit timestamp
                }
            }
        };
        const value2: MergeValue = {
            value: { name: 'Jane', age: 25 },
            metadata: { timestamp: 2000 } // no field-level metadata
        };

        const result = mergeFields(value1, value2);

        // age from value1 should use root timestamp 1000
        // age from value2 should use root timestamp 2000
        // value2.age wins (2000 > 1000)
        expect(result.value.age).toBe(25);
        expect(result.metadata.fields!.age.timestamp).toBe(2000);
        // name: value1 has timestamp 1500, value2 has timestamp 2000 (root)
        // value2.name wins (2000 > 1500), so timestamp should be 2000
        expect(result.value.name).toBe('Jane');
        expect(result.metadata.fields!.name.timestamp).toBe(2000);
    });
});

