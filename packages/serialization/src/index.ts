//
// Binary serialization and deserialization with versioning support.
//

export { 
    save, 
    load, 
    UnsupportedVersionError,
    BinarySerializer,
    BinaryDeserializer,
    type ISerializer,
    type IDeserializer,
    type SerializerFunction,
    type DeserializerFunction,
    type DeserializerMap
} from './lib/serialization';