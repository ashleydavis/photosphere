//
// Binary serialization and deserialization with versioning support.
//

export {
    save,
    load,
    loadVersion,
    verify,
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
    type MigrationMap,
    type IVerifyResult
} from './lib/serialization';