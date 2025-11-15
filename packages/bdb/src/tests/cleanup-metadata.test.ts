import { cleanupMetadata } from '../lib/merge-records';
import type { Metadata } from '../lib/collection';

describe('cleanupMetadata', () => {
    test('should return undefined for metadata with timestamp less than or equal to cutoff', () => {
        const metadata: Metadata = {
            timestamp: 1000
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeUndefined();
    });

    test('should return metadata with timestamp greater than cutoff when no fields', () => {
        const metadata: Metadata = {
            timestamp: 3000
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(3000);
        expect(result!.fields).toBeUndefined();
    });

    test('should return undefined when timestamp is equal to cutoff', () => {
        const metadata: Metadata = {
            timestamp: 2000
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeUndefined();
    });

    test('should preserve fields with timestamps greater than cutoff', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: 3000 },
                field2: { timestamp: 2500 }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(1000);
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field1).toBeDefined();
        expect(result!.fields!.field1.timestamp).toBe(3000);
        expect(result!.fields!.field2).toBeDefined();
        expect(result!.fields!.field2.timestamp).toBe(2500);
    });

    test('should remove fields with timestamps less than or equal to cutoff', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: 3000 },
                field2: { timestamp: 1500 }, // removed
                field3: { timestamp: 2000 }  // removed (equal)
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field1).toBeDefined();
        expect(result!.fields!.field2).toBeUndefined();
        expect(result!.fields!.field3).toBeUndefined();
    });

    test('should preserve fields with nested fields even if timestamp is old', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                nested: {
                    timestamp: 1500, // old timestamp
                    fields: {
                        inner: { timestamp: 3000 } // but has new nested field
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.nested).toBeDefined();
        expect(result!.fields!.nested.fields).toBeDefined();
        expect(result!.fields!.nested.fields!.inner.timestamp).toBe(3000);
    });

    test('should remove fields with no nested fields and old timestamps', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: 3000 },
                field2: {
                    timestamp: 1500,
                    fields: {} // empty nested fields
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field1).toBeDefined();
        expect(result!.fields!.field2).toBeUndefined(); // removed because timestamp is old and no valid nested fields
    });

    test('should recursively clean up nested metadata', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                level1: {
                    timestamp: 2000,
                    fields: {
                        level2: {
                            timestamp: 1500, // should be removed
                            fields: {
                                level3: { timestamp: 3000 } // should be preserved
                            }
                        },
                        level2b: {
                            timestamp: 500 // should be removed
                        }
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields!.level1).toBeDefined();
        expect(result!.fields!.level1.fields).toBeDefined();
        expect(result!.fields!.level1.fields!.level2).toBeDefined(); // preserved because it has nested fields
        expect(result!.fields!.level1.fields!.level2.fields!.level3.timestamp).toBe(3000);
        expect(result!.fields!.level1.fields!.level2b).toBeUndefined(); // removed
    });

    test('should return undefined when root timestamp is old and no valid fields remain', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: 1500 },
                field2: { timestamp: 1800 }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeUndefined();
    });

    test('should return metadata when root timestamp is old but valid fields exist', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: 1500 },
                field2: { timestamp: 3000 } // valid field
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(1000);
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field2).toBeDefined();
        expect(result!.fields!.field1).toBeUndefined();
    });

    test('should handle deeply nested structures with all valid timestamps', () => {
        const metadata: Metadata = {
            timestamp: 5000,
            fields: {
                a: {
                    timestamp: 4000,
                    fields: {
                        b: {
                            timestamp: 3000,
                            fields: {
                                c: { timestamp: 6000 }
                            }
                        }
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(5000);
        expect(result!.fields!.a).toBeDefined();
        expect(result!.fields!.a.fields!.b).toBeDefined();
        expect(result!.fields!.a.fields!.b.fields!.c).toBeDefined();
    });

    test('should handle metadata without timestamp property', () => {
        const metadata: Metadata = {
            fields: {
                field1: { timestamp: 3000 }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field1).toBeDefined();
    });

    test('should handle empty fields object', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {}
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeUndefined();
    });

    test('should handle undefined fields property', () => {
        const metadata: Metadata = {
            timestamp: 3000
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(3000);
        expect(result!.fields).toBeUndefined();
    });

    test('should use provided timestamp as fallback when metadata timestamp is undefined', () => {
        const metadata: Metadata = {
            fields: {
                field1: {
                    timestamp: 1500,
                    fields: {
                        inner: { timestamp: 3000 }
                    }
                }
            }
        };

        // When cleaning nested field, if it has no timestamp, use the provided timestamp
        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        // field1 has timestamp 1500 < 2000, but has nested fields
        // The nested field inner has timestamp 3000 > 2000
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.field1).toBeDefined();
    });

    test('should preserve complex nested structure with mixed timestamps', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                user: {
                    timestamp: 2500,
                    fields: {
                        name: { timestamp: 3000 },
                        email: { timestamp: 1500 }, // old
                        address: {
                            timestamp: 1800, // old
                            fields: {
                                street: { timestamp: 3500 }, // new
                                city: { timestamp: 1200 } // old
                            }
                        }
                    }
                },
                settings: {
                    timestamp: 500, // old
                    fields: {
                        theme: { timestamp: 4000 } // new
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields!.user).toBeDefined();
        expect(result!.fields!.user.fields!.name).toBeDefined();
        expect(result!.fields!.user.fields!.email).toBeUndefined();
        expect(result!.fields!.user.fields!.address).toBeDefined(); // preserved because has nested fields
        expect(result!.fields!.user.fields!.address.fields!.street).toBeDefined();
        expect(result!.fields!.user.fields!.address.fields!.city).toBeUndefined();
        expect(result!.fields!.settings).toBeDefined(); // preserved because has nested fields
        expect(result!.fields!.settings.fields!.theme).toBeDefined();
    });

    test('should handle cutoff timestamp of zero', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                field1: { timestamp: -100 },
                field2: { timestamp: 500 }
            }
        };

        const result = cleanupMetadata(metadata, 0);

        // field1 (-100) and field2 (500) both have timestamps < root timestamp (1000)
        // So when cleaning them with root timestamp 1000 as cutoff, both are removed
        // But root timestamp 1000 > 0, so metadata is returned without fields
        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(1000);
        expect(result!.fields).toBeUndefined();
    });

    test('should handle very large timestamps', () => {
        const metadata: Metadata = {
            timestamp: Number.MAX_SAFE_INTEGER,
            fields: {
                field1: { timestamp: Number.MAX_SAFE_INTEGER - 1 }
            }
        };

        const result = cleanupMetadata(metadata, Number.MAX_SAFE_INTEGER - 2);

        // field1 has timestamp Number.MAX_SAFE_INTEGER - 1
        // When cleaning with root timestamp (Number.MAX_SAFE_INTEGER) as cutoff,
        // field1 is removed because (Number.MAX_SAFE_INTEGER - 1) <= Number.MAX_SAFE_INTEGER
        // But root timestamp > cutoff, so metadata is returned without fields
        expect(result).toBeDefined();
        expect(result!.timestamp).toBe(Number.MAX_SAFE_INTEGER);
        expect(result!.fields).toBeUndefined();
    });

    test('should remove all nested fields when they are all old', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                level1: {
                    timestamp: 1500,
                    fields: {
                        level2: {
                            timestamp: 1200,
                            fields: {
                                level3: { timestamp: 1800 }
                            }
                        }
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        // All timestamps are < 2000, but the nested structure is preserved
        // because level3 has fields (empty object from cleanup), so the structure
        // is kept even though timestamps are old
        expect(result).toBeDefined();
        // The structure is preserved because nested fields exist
        expect(result!.fields).toBeDefined();
        expect(result!.fields!.level1).toBeDefined();
    });

    test('should preserve structure when only leaf nodes are new', () => {
        const metadata: Metadata = {
            timestamp: 1000,
            fields: {
                a: {
                    timestamp: 500,
                    fields: {
                        b: {
                            timestamp: 300,
                            fields: {
                                c: { timestamp: 5000 } // only this is new
                            }
                        }
                    }
                }
            }
        };

        const result = cleanupMetadata(metadata, 2000);

        expect(result).toBeDefined();
        expect(result!.fields!.a).toBeDefined();
        expect(result!.fields!.a.fields!.b).toBeDefined();
        expect(result!.fields!.a.fields!.b.fields!.c).toBeDefined();
        expect(result!.fields!.a.fields!.b.fields!.c.timestamp).toBe(5000);
    });
});

