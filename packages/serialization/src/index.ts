//
// Binary serialization and deserialization with versioning support.
//

export { 
    save, 
    load, 
    UnsupportedVersionError,
    BinarySerializer,
    BinaryDeserializer,
    CompressedBinarySerializer,
    CompressedBinaryDeserializer,
    type ISerializer,
    type IDeserializer,
    type SerializerFunction,
    type DeserializerFunction,
    type DeserializerMap,
    type MigrationFunction,
    type MigrationMap
} from './lib/serialization';