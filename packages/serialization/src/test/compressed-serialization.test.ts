//
// Tests for CompressedBinarySerializer and CompressedBinaryDeserializer
//

import { 
    CompressedBinarySerializer, 
    CompressedBinaryDeserializer,
    BinarySerializer,
    BinaryDeserializer,
    type ISerializer,
    type IDeserializer
} from '../lib/serialization';

describe('CompressedBinarySerializer and CompressedBinaryDeserializer', () => {
    
    describe('CompressedBinarySerializer', () => {
        it('should compress data and write to main serializer', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Write some data
            compressedSerializer.writeString('Hello, World!');
            compressedSerializer.writeUInt32(42);
            compressedSerializer.writeBoolean(true);
            
            // Finish compression
            compressedSerializer.finish();
            
            // Get the compressed data from main serializer
            const mainBuffer = mainSerializer.getBuffer();
            expect(mainBuffer.length).toBeGreaterThan(0);
            
            // The compressed data should be smaller than uncompressed for this simple case
            // (though gzip overhead might make it larger for very small data)
            const compressedLength = mainBuffer.readUInt32LE(0);
            expect(compressedLength).toBeGreaterThan(0);
            expect(compressedLength).toBeLessThanOrEqual(mainBuffer.length - 4);
        });

        it('should handle empty data', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Write nothing, just finish
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            expect(mainBuffer.length).toBeGreaterThanOrEqual(4); // At least length prefix
        });

        it('should compress large amounts of data effectively', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Write a lot of repetitive data (should compress well)
            const repeatedString = 'This is a test string that will be repeated many times. ';
            for (let i = 0; i < 100; i++) {
                compressedSerializer.writeString(repeatedString + i);
            }
            
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const compressedLength = mainBuffer.readUInt32LE(0);
            
            // Compressed data should be significantly smaller than uncompressed
            // For repetitive data, compression should be very effective
            const uncompressedSize = 100 * (repeatedString.length + 20); // Approximate
            expect(compressedLength).toBeLessThan(uncompressedSize / 2);
        });

        it('should support all write methods', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Test all write methods
            compressedSerializer.writeUInt32(12345);
            compressedSerializer.writeInt32(-12345);
            compressedSerializer.writeUInt64(BigInt('9007199254740991'));
            compressedSerializer.writeInt64(BigInt('-9007199254740991'));
            compressedSerializer.writeFloat(3.14159); // This will be rounded to nearest representable float
            compressedSerializer.writeDouble(3.141592653589793);
            compressedSerializer.writeBoolean(true);
            compressedSerializer.writeBoolean(false);
            compressedSerializer.writeUInt8(255);
            compressedSerializer.writeString('test string');
            compressedSerializer.writeBuffer(Buffer.from('test buffer'));
            compressedSerializer.writeBytes(Buffer.from([1, 2, 3, 4, 5]));
            compressedSerializer.writeBSON({ name: 'test', value: 42 });
            
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            expect(mainBuffer.length).toBeGreaterThan(0);
        });

        it('should use custom initial capacity', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer, 2048);
            
            compressedSerializer.writeString('test');
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            expect(mainBuffer.length).toBeGreaterThan(0);
        });
    });

    describe('CompressedBinaryDeserializer', () => {
        it('should decompress and read data correctly', () => {
            // Serialize with compression
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            compressedSerializer.writeString('Hello, World!');
            compressedSerializer.writeUInt32(42);
            compressedSerializer.writeBoolean(true);
            compressedSerializer.finish();
            
            // Deserialize
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            // Read back the data
            expect(compressedDeserializer.readString()).toBe('Hello, World!');
            expect(compressedDeserializer.readUInt32()).toBe(42);
            expect(compressedDeserializer.readBoolean()).toBe(true);
        });

        it('should handle round-trip for all data types', () => {
            // Serialize
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Use exact float values that can be precisely represented in 32-bit IEEE 754
            const exactFloat = 123.5; // Exactly representable: 123.5 = 123 + 1/2
            const exactFloat2 = -42.25; // Exactly representable: -42.25 = -42 - 1/4
            const exactDouble = 3.141592653589793;
            
            compressedSerializer.writeUInt32(12345);
            compressedSerializer.writeInt32(-12345);
            compressedSerializer.writeUInt64(BigInt('9007199254740991'));
            compressedSerializer.writeInt64(BigInt('-9007199254740991'));
            compressedSerializer.writeFloat(exactFloat);
            compressedSerializer.writeFloat(exactFloat2);
            compressedSerializer.writeDouble(exactDouble);
            compressedSerializer.writeBoolean(true);
            compressedSerializer.writeBoolean(false);
            compressedSerializer.writeUInt8(255);
            compressedSerializer.writeString('test string');
            const testBuffer = Buffer.from('test buffer');
            compressedSerializer.writeBuffer(testBuffer);
            compressedSerializer.writeBytes(Buffer.from([1, 2, 3, 4, 5]));
            compressedSerializer.writeBSON({ name: 'test', value: 42 });
            compressedSerializer.finish();
            
            // Deserialize
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            // Verify all values - floats should be exact
            expect(compressedDeserializer.readUInt32()).toBe(12345);
            expect(compressedDeserializer.readInt32()).toBe(-12345);
            expect(compressedDeserializer.readUInt64()).toBe(BigInt('9007199254740991'));
            expect(compressedDeserializer.readInt64()).toBe(BigInt('-9007199254740991'));
            expect(compressedDeserializer.readFloat()).toBe(exactFloat);
            expect(compressedDeserializer.readFloat()).toBe(exactFloat2);
            expect(compressedDeserializer.readDouble()).toBe(exactDouble);
            expect(compressedDeserializer.readBoolean()).toBe(true);
            expect(compressedDeserializer.readBoolean()).toBe(false);
            expect(compressedDeserializer.readUInt8()).toBe(255);
            expect(compressedDeserializer.readString()).toBe('test string');
            expect(compressedDeserializer.readBuffer()).toEqual(testBuffer);
            expect(compressedDeserializer.readBytes(5)).toEqual(Buffer.from([1, 2, 3, 4, 5]));
            expect(compressedDeserializer.readBSON()).toEqual({ name: 'test', value: 42 });
        });

        it('should handle empty compressed data', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            // Should be able to create deserializer even with empty data
            expect(compressedDeserializer).toBeDefined();
        });

        it('should handle large amounts of data', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Write many strings
            const strings: string[] = [];
            for (let i = 0; i < 1000; i++) {
                const str = `String number ${i} with some content`;
                strings.push(str);
                compressedSerializer.writeString(str);
            }
            compressedSerializer.finish();
            
            // Deserialize
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            // Read back all strings
            for (let i = 0; i < 1000; i++) {
                expect(compressedDeserializer.readString()).toBe(strings[i]);
            }
        });

        it('should handle binary data with null bytes', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            const binaryData = Buffer.from([0x00, 0x01, 0x02, 0xFF, 0x00, 0xAA]);
            compressedSerializer.writeBuffer(binaryData);
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            const result = compressedDeserializer.readBuffer();
            expect(result).toEqual(binaryData);
        });

        it('should handle Unicode strings', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            const unicodeStrings = [
                'Hello, World!',
                '🚀 Unicode test',
                'émojis and spëcial chars',
                '中文测试',
                '日本語テスト',
                'Русский тест'
            ];
            
            for (const str of unicodeStrings) {
                compressedSerializer.writeString(str);
            }
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            for (const str of unicodeStrings) {
                expect(compressedDeserializer.readString()).toBe(str);
            }
        });

        it('should handle BSON objects with complex structures', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            const complexObj = {
                name: 'test',
                value: 42,
                nested: {
                    array: [1, 2, 3, 4, 5],
                    bool: true,
                    date: new Date('2023-01-01'),
                    deep: {
                        level: 3,
                        data: 'deep value'
                    }
                },
                tags: ['tag1', 'tag2', 'tag3']
            };
            
            compressedSerializer.writeBSON(complexObj);
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            const result = compressedDeserializer.readBSON();
            expect(result).toEqual(complexObj);
        });

        it('should handle multiple compressed blocks in sequence', () => {
            const mainSerializer = new BinarySerializer();
            
            // First compressed block
            const compressedSerializer1 = new CompressedBinarySerializer(mainSerializer);
            compressedSerializer1.writeString('First block');
            compressedSerializer1.writeUInt32(1);
            compressedSerializer1.finish();
            
            // Second compressed block
            const compressedSerializer2 = new CompressedBinarySerializer(mainSerializer);
            compressedSerializer2.writeString('Second block');
            compressedSerializer2.writeUInt32(2);
            compressedSerializer2.finish();
            
            // Deserialize both blocks
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            
            // Read first block
            const compressedDeserializer1 = new CompressedBinaryDeserializer(mainDeserializer);
            expect(compressedDeserializer1.readString()).toBe('First block');
            expect(compressedDeserializer1.readUInt32()).toBe(1);
            
            // Read second block
            const compressedDeserializer2 = new CompressedBinaryDeserializer(mainDeserializer);
            expect(compressedDeserializer2.readString()).toBe('Second block');
            expect(compressedDeserializer2.readUInt32()).toBe(2);
        });

        it('should maintain data integrity across compression', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            // Write various data types
            // Use exact float values that can be precisely represented
            const exactFloat = 1000.0; // Integer values are exactly representable
            const exactFloat2 = 0.5; // Powers of 2 are exactly representable
            const exactFloat3 = -123.125; // -123.125 = -123 - 1/8, exactly representable
            const testDouble = Number.MIN_SAFE_INTEGER;
            
            compressedSerializer.writeUInt32(0xFFFFFFFF);
            compressedSerializer.writeInt32(-0x7FFFFFFF);
            compressedSerializer.writeUInt64(BigInt('18446744073709551615'));
            compressedSerializer.writeInt64(BigInt('-9223372036854775808'));
            compressedSerializer.writeFloat(exactFloat);
            compressedSerializer.writeFloat(exactFloat2);
            compressedSerializer.writeFloat(exactFloat3);
            compressedSerializer.writeDouble(testDouble);
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            expect(compressedDeserializer.readUInt32()).toBe(0xFFFFFFFF);
            expect(compressedDeserializer.readInt32()).toBe(-0x7FFFFFFF);
            expect(compressedDeserializer.readUInt64()).toBe(BigInt('18446744073709551615'));
            expect(compressedDeserializer.readInt64()).toBe(BigInt('-9223372036854775808'));
            // Floats should be exact
            expect(compressedDeserializer.readFloat()).toBe(exactFloat);
            expect(compressedDeserializer.readFloat()).toBe(exactFloat2);
            expect(compressedDeserializer.readFloat()).toBe(exactFloat3);
            expect(compressedDeserializer.readDouble()).toBe(testDouble);
        });

        it('should handle edge case values', () => {
            const mainSerializer = new BinarySerializer();
            const compressedSerializer = new CompressedBinarySerializer(mainSerializer);
            
            compressedSerializer.writeUInt32(0);
            compressedSerializer.writeInt32(0);
            compressedSerializer.writeUInt64(BigInt(0));
            compressedSerializer.writeInt64(BigInt(0));
            compressedSerializer.writeFloat(0);
            compressedSerializer.writeDouble(0);
            compressedSerializer.writeBoolean(false);
            compressedSerializer.writeUInt8(0);
            compressedSerializer.writeString('');
            compressedSerializer.writeBuffer(Buffer.alloc(0));
            compressedSerializer.finish();
            
            const mainBuffer = mainSerializer.getBuffer();
            const mainDeserializer = new BinaryDeserializer(mainBuffer);
            const compressedDeserializer = new CompressedBinaryDeserializer(mainDeserializer);
            
            expect(compressedDeserializer.readUInt32()).toBe(0);
            expect(compressedDeserializer.readInt32()).toBe(0);
            expect(compressedDeserializer.readUInt64()).toBe(BigInt(0));
            expect(compressedDeserializer.readInt64()).toBe(BigInt(0));
            expect(compressedDeserializer.readFloat()).toBe(0);
            expect(compressedDeserializer.readDouble()).toBe(0);
            expect(compressedDeserializer.readBoolean()).toBe(false);
            expect(compressedDeserializer.readUInt8()).toBe(0);
            expect(compressedDeserializer.readString()).toBe('');
            expect(compressedDeserializer.readBuffer()).toEqual(Buffer.alloc(0));
        });
    });

    describe('Integration with BinarySerializer/BinaryDeserializer', () => {
        it('should work with nested compression', () => {
            // Create outer serializer
            const outerSerializer = new BinarySerializer();
            const outerCompressed = new CompressedBinarySerializer(outerSerializer);
            
            // Create inner serializer within compressed block
            const innerSerializer = new BinarySerializer();
            const innerCompressed = new CompressedBinarySerializer(innerSerializer);
            
            // Write to inner compressed serializer
            innerCompressed.writeString('Inner data');
            innerCompressed.writeUInt32(100);
            innerCompressed.finish();
            
            // Write inner compressed data to outer compressed serializer
            const innerBuffer = innerSerializer.getBuffer();
            outerCompressed.writeBuffer(innerBuffer);
            outerCompressed.writeString('Outer data');
            outerCompressed.finish();
            
            // Deserialize outer
            const outerBuffer = outerSerializer.getBuffer();
            const outerDeserializer = new BinaryDeserializer(outerBuffer);
            const outerCompressedDeserializer = new CompressedBinaryDeserializer(outerDeserializer);
            
            // Read inner buffer
            const innerBufferRead = outerCompressedDeserializer.readBuffer();
            expect(outerCompressedDeserializer.readString()).toBe('Outer data');
            
            // Deserialize inner
            const innerDeserializer = new BinaryDeserializer(innerBufferRead);
            const innerCompressedDeserializer = new CompressedBinaryDeserializer(innerDeserializer);
            
            expect(innerCompressedDeserializer.readString()).toBe('Inner data');
            expect(innerCompressedDeserializer.readUInt32()).toBe(100);
        });
    });
});

