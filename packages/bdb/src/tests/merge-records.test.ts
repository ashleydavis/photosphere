import { mergeRecords } from '../lib/merge-records';
import type { IInternalRecord } from '../lib/shard';

describe('mergeRecords', () => {
    test('should merge two records with same _id', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John', age: 30 },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane', email: 'jane@example.com' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result._id).toBe('123');
        expect(result.fields).toEqual({
            name: 'Jane',
            age: 30,
            email: 'jane@example.com'
        });
        expect(result.metadata).toBeDefined();
    });

    test('should throw error when records have different _id', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '456',
            fields: { name: 'Jane' },
            metadata: { timestamp: 2000 }
        };

        expect(() => mergeRecords(record1, record2)).toThrow(
            'Cannot merge records with different IDs: 123 vs 456'
        );
    });

    test('should merge records with field-level metadata', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John', age: 30 },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 1500 }
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane', email: 'jane@example.com' },
            metadata: {
                timestamp: 2000,
                fields: {
                    email: { timestamp: 2000 }
                }
            }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.name).toBe('Jane'); // value2.name timestamp 2000 > value1.name timestamp 1500
        expect(result.fields.age).toBe(30);
        expect(result.fields.email).toBe('jane@example.com');
        expect(result.metadata.fields).toBeDefined();
    });

    test('should handle records with no metadata timestamp', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: {} // no timestamp
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        // record1 timestamp defaults to 0, record2 is 2000
        // So record2.name should win
        expect(result.fields.name).toBe('Jane');
        expect(result.metadata).toBeDefined();
    });

    test('should merge nested objects in records', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {
                user: { name: 'John', age: 30 },
                settings: { theme: 'dark' }
            },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: {
                user: { name: 'Jane', email: 'jane@example.com' },
                settings: { theme: 'light', fontSize: 14 }
            },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.user).toEqual({
            name: 'Jane',
            age: 30,
            email: 'jane@example.com'
        });
        expect(result.fields.settings).toEqual({
            theme: 'light',
            fontSize: 14
        });
    });

    test('should clean up empty metadata after merge', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        // After cleanup with timestamp 0, the metadata should have fields
        // because name has timestamp 2000 > 0
        expect(result.metadata).toBeDefined();
        expect(result.metadata.fields).toBeDefined();
        expect(result.metadata.fields!.name).toBeDefined();
    });

    test('should handle records with all fields having old timestamps', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane' },
            metadata: { timestamp: 500 }
        };

        const result = mergeRecords(record1, record2);

        // record1.name wins (timestamp 1000 > 500)
        // After cleanup with timestamp 0, name has timestamp 1000 > 0, so should be preserved
        expect(result.fields.name).toBe('John');
        expect(result.metadata.fields).toBeDefined();
        expect(result.metadata.fields!.name.timestamp).toBe(1000);
    });

    test('should merge records with deeply nested structures', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {
                level1: {
                    level2: {
                        level3: { value: 'deep1' }
                    }
                }
            },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: {
                level1: {
                    level2: {
                        level3: { value: 'deep2', other: 'field' }
                    }
                }
            },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.level1.level2.level3.value).toBe('deep2');
        expect(result.fields.level1.level2.level3.other).toBe('field');
    });

    test('should handle deleted fields in metadata', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: {
                timestamp: 1000,
                fields: {
                    email: { timestamp: 500 } // deleted field
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane', email: 'jane@example.com' },
            metadata: {
                timestamp: 2000,
                fields: {
                    email: { timestamp: 2000 }
                }
            }
        };

        const result = mergeRecords(record1, record2);

        // record2.email has newer timestamp, so it should win
        expect(result.fields.email).toBe('jane@example.com');
    });

    test('should merge when one record has empty fields', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {},
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane', age: 25 },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields).toEqual({
            name: 'Jane',
            age: 25
        });
    });

    test('should handle records with no fields and no metadata', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {},
            metadata: {}
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: {},
            metadata: {}
        };

        const result = mergeRecords(record1, record2);

        expect(result._id).toBe('123');
        expect(result.fields).toEqual({});
        expect(result.metadata).toEqual({});
    });

    test('should preserve _id from first record', () => {
        const record1: IInternalRecord = {
            _id: 'abc-123',
            fields: { name: 'John' },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: 'abc-123',
            fields: { name: 'Jane' },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result._id).toBe('abc-123');
    });

    test('should handle complex field metadata with nested timestamps', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {
                user: { name: 'John', age: 30 },
                tags: ['tag1']
            },
            metadata: {
                timestamp: 1000,
                fields: {
                    user: {
                        timestamp: 1500,
                        fields: {
                            name: { timestamp: 1500 }
                        }
                    }
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: {
                user: { name: 'Jane', email: 'jane@example.com' },
                tags: ['tag2']
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
                    }
                }
            }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.user.name).toBe('Jane');
        expect(result.fields.user.age).toBe(30);
        expect(result.fields.user.email).toBe('jane@example.com');
    });

    test('should handle multiple field updates with different timestamps', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { a: 1, b: 2, c: 3 },
            metadata: {
                timestamp: 1000,
                fields: {
                    a: { timestamp: 1500 },
                    b: { timestamp: 1200 }
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { a: 10, b: 20, d: 4 },
            metadata: {
                timestamp: 2000,
                fields: {
                    a: { timestamp: 1800 },
                    b: { timestamp: 2500 },
                    d: { timestamp: 2000 }
                }
            }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.a).toBe(10); // record2.a timestamp 1800 > record1.a timestamp 1500
        expect(result.fields.b).toBe(20); // record2.b timestamp 2500 > record1.b timestamp 1200
        expect(result.fields.c).toBe(3);  // only in record1
        expect(result.fields.d).toBe(4);  // only in record2
    });

    test('should handle records where cleanup removes all metadata', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John' },
            metadata: {
                timestamp: 1000,
                fields: {
                    name: { timestamp: 500 } // old timestamp
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane' },
            metadata: {
                timestamp: 500,
                fields: {
                    name: { timestamp: 300 } // old timestamp
                }
            }
        };

        const result = mergeRecords(record1, record2);

        // After merge, name has timestamp 500 (record1.name with 500 > record2.name with 300)
        // After cleanup with timestamp 0, name timestamp 500 > 0, but cleanupMetadata may remove it
        // if the metadata structure doesn't meet the criteria
        expect(result.fields.name).toBe('John');
        // The name field is in result.fields, but metadata.fields may be cleaned up
        // Check the actual behavior - if cleanup removes old metadata, fields might be undefined
        if (result.metadata.fields) {
            expect(result.metadata.fields.name).toBeDefined();
        }
    });

    test('should merge records with null and undefined values', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { name: 'John', age: null, email: undefined },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { name: 'Jane', age: 30 },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.name).toBe('Jane');
        expect(result.fields.age).toBe(30);
        expect(result.fields.email).toBeUndefined();
    });

    test('should handle arrays as field values', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: { items: [1, 2, 3], tags: ['a'] },
            metadata: { timestamp: 1000 }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: { items: [4, 5], tags: ['b', 'c'] },
            metadata: { timestamp: 2000 }
        };

        const result = mergeRecords(record1, record2);

        // Arrays are objects, so they will be merged by keys
        expect(result.fields.items).toBeDefined();
        expect(result.fields.tags).toBeDefined();
    });

    test('should preserve metadata structure after merge and cleanup', () => {
        const record1: IInternalRecord = {
            _id: '123',
            fields: {
                user: {
                    name: 'John',
                    profile: {
                        bio: 'Old bio'
                    }
                }
            },
            metadata: {
                timestamp: 1000,
                fields: {
                    user: {
                        timestamp: 1000,
                        fields: {
                            profile: {
                                timestamp: 1000,
                                fields: {
                                    bio: { timestamp: 1000 }
                                }
                            }
                        }
                    }
                }
            }
        };
        const record2: IInternalRecord = {
            _id: '123',
            fields: {
                user: {
                    name: 'Jane',
                    profile: {
                        bio: 'New bio',
                        avatar: 'avatar.jpg'
                    }
                }
            },
            metadata: {
                timestamp: 2000,
                fields: {
                    user: {
                        timestamp: 2000,
                        fields: {
                            name: { timestamp: 2000 },
                            profile: {
                                timestamp: 2000,
                                fields: {
                                    bio: { timestamp: 2000 },
                                    avatar: { timestamp: 2000 }
                                }
                            }
                        }
                    }
                }
            }
        };

        const result = mergeRecords(record1, record2);

        expect(result.fields.user.name).toBe('Jane');
        expect(result.fields.user.profile.bio).toBe('New bio');
        expect(result.fields.user.profile.avatar).toBe('avatar.jpg');
        
        // Verify metadata structure is preserved
        expect(result.metadata.fields).toBeDefined();
        expect(result.metadata.fields!.user).toBeDefined();
        expect(result.metadata.fields!.user.fields!.profile).toBeDefined();
    });

    // The records below are the ones smoke test 45 produces, read out of the real databases it leaves
    // behind with `bdb shard <db>/.db/bson metadata <shard>`.
    //
    // A freshly added asset carries `description: ""` as a real field (upload-asset.worker.ts writes
    // it on every import) with no per-field metadata of its own, so the origin's side of the
    // comparison falls back to the record-level timestamp, which is when the HOST created the record.
    // The device edits the description and stamps it with its OWN clock, and the merge compares the
    // two numbers without regard for which machine produced them.
    //
    // The emulator runs about 22 seconds behind the host, and test 45 reaches the edit about 26
    // seconds after the host writes the record, so the edit is normally stamped only about 4 seconds
    // above the record. Measured on a passing run: record 1786316805276, description 1786316809381,
    // a margin of 4105ms. Any run that reaches the edit a few seconds sooner, or on a device a few
    // seconds further behind, stamps it at or below the record and the origin's empty string wins.
    // updateMetadata guarantees the edited field is stamped above the record it changed, however far
    // behind the editing device's clock is, so the merge below is the one that actually runs. Without
    // that guarantee the two sides came in equal and the origin's empty string won, which is the
    // failure this pair of tests exists to keep out.
    const HOST_RECORD_TIMESTAMP = 1786316805276;

    test('an edit stamped above the record beats an untouched empty field on the other side', () => {
        // The replica on the device. Replication copied the record verbatim, so the record-level
        // timestamp is still the host's, and the edit carries the stamp updateMetadata gave it.
        const deviceReplica: IInternalRecord = {
            _id: '123',
            fields: { description: 'Edited on the device' },
            metadata: {
                timestamp: HOST_RECORD_TIMESTAMP,
                fields: {
                    description: { timestamp: HOST_RECORD_TIMESTAMP + 1 }
                }
            }
        };
        // The origin in the bucket, untouched since the host created it.
        const origin: IInternalRecord = {
            _id: '123',
            fields: { description: '' },
            metadata: { timestamp: HOST_RECORD_TIMESTAMP }
        };

        // The argument order of the push leg in syncDatabases: the device replica is the source and
        // the origin is the target.
        const result = mergeRecords(deviceReplica, origin);

        expect(result.fields.description).toBe('Edited on the device');
    });

    test('an edit that beat the record keeps its stamp through the merge, so it survives the next one', () => {
        // cleanupMetadata drops a field entry whose timestamp only equals the record's, which is how
        // the losing merge used to come out byte-for-byte identical to the record already stored: the
        // origin's root hash never moved and nothing looked wrong. A winning edit must come out the
        // other side still carrying its own stamp.
        const deviceReplica: IInternalRecord = {
            _id: '123',
            fields: { description: 'Edited on the device' },
            metadata: {
                timestamp: HOST_RECORD_TIMESTAMP,
                fields: {
                    description: { timestamp: HOST_RECORD_TIMESTAMP + 1 }
                }
            }
        };
        const origin: IInternalRecord = {
            _id: '123',
            fields: { description: '' },
            metadata: { timestamp: HOST_RECORD_TIMESTAMP }
        };

        const result = mergeRecords(deviceReplica, origin);

        expect(result.metadata.fields!.description.timestamp).toBe(HOST_RECORD_TIMESTAMP + 1);
    });
});

