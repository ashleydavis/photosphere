import Foundation
import Security

//
// The native RSA crypto behind the two host.crypto* functions. The embedded engine has no RSA key
// generation or signing; LAN-share's receiver self-signs its TLS certificate in TypeScript, but the
// key-pair generation and the SHA256withRSA signature must come from native crypto. This mirrors the
// Android CryptoHost: cryptoGenerateRsaKeyPair returns a PKCS#8 private / SPKI public PEM pair, and
// cryptoSignSha256 signs with the PKCS#8 private key. All methods are stateless, so the engine pool
// can call them concurrently.
//
// Apple's SecKey external representation for RSA is PKCS#1 (RSAPrivateKey / RSAPublicKey), while the
// TypeScript side and Android use PKCS#8 / SPKI PEM. These helpers wrap PKCS#1 into PKCS#8 / SPKI (for
// export) and unwrap PKCS#8 back to PKCS#1 (for import), so the PEM contract is identical on both
// platforms.
//
enum CryptoHost {

    //
    // The DER AlgorithmIdentifier for rsaEncryption (OID 1.2.840.113549.1.1.1 with a NULL parameter),
    // shared by the PKCS#8 and SPKI wrappers.
    //
    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
    ]

    //
    // host.cryptoGenerateRsaKeyPair(modulusLength): generates an RSA key pair and returns a JSON string
    // { privateKeyPem, publicKeyPem } (PKCS#8 private, SPKI public, both PEM). On failure returns a host
    // error envelope so the JS crypto shim throws.
    //
    static func cryptoGenerateRsaKeyPair(modulusLength: Int) -> String {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: modulusLength
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoGenerateRsaKeyPair: key generation failed", error))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoGenerateRsaKeyPair: public key derivation failed"]))
        }

        guard let privatePkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoGenerateRsaKeyPair: private key export failed", error))
        }
        guard let publicPkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoGenerateRsaKeyPair: public key export failed", error))
        }

        let privatePem = toPem(type: "PRIVATE KEY", der: wrapPkcs8(pkcs1Private: [UInt8](privatePkcs1)))
        let publicPem = toPem(type: "PUBLIC KEY", der: wrapSpki(pkcs1Public: [UInt8](publicPkcs1)))

        return "{\"privateKeyPem\":\"\(HostBridge.jsonEscape(privatePem))\",\"publicKeyPem\":\"\(HostBridge.jsonEscape(publicPem))\"}"
    }

    //
    // host.cryptoSignSha256(privateKeyPem, dataBase64): signs the base64-decoded data with
    // SHA256withRSA (PKCS#1 v1.5) using the PEM PKCS#8 private key and returns the base64 signature. On
    // failure returns a host error envelope so the JS crypto shim throws.
    //
    static func cryptoSignSha256(privateKeyPem: String, dataBase64: String) -> String {
        guard let data = Data(base64Encoded: dataBase64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoSignSha256: invalid base64 data"]))
        }

        let pkcs8 = derFromPem(privateKeyPem)
        guard let pkcs1 = unwrapPkcs8(pkcs8: pkcs8) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoSignSha256: could not parse PKCS#8 private key"]))
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoSignSha256: could not import private key", error))
        }

        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoSignSha256: signing failed", error))
        }

        return signature.base64EncodedString()
    }

    //
    // host.cryptoPublicEncryptOaepSha1(publicKeyPem, dataBase64): RSA-encrypts the base64-decoded data
    // with the SPKI PEM public key using OAEP (SHA-1 digest + MGF1, matching Node's default padding) and
    // returns the base64 ciphertext. On failure returns a host error envelope so the JS crypto shim throws.
    //
    static func cryptoPublicEncryptOaepSha1(publicKeyPem: String, dataBase64: String) -> String {
        guard let data = Data(base64Encoded: dataBase64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPublicEncryptOaepSha1: invalid base64 data"]))
        }

        let spki = derFromPem(publicKeyPem)
        guard let pkcs1 = unwrapSpki(spki: spki) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPublicEncryptOaepSha1: could not parse SPKI public key"]))
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPublicEncryptOaepSha1: could not import public key", error))
        }
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA1, data as CFData, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPublicEncryptOaepSha1: encryption failed", error))
        }
        return encrypted.base64EncodedString()
    }

    //
    // host.cryptoPrivateDecryptOaepSha1(privateKeyPem, dataBase64): RSA-decrypts the base64-decoded data
    // with the PKCS#8 PEM private key using OAEP (SHA-1 digest + MGF1) and returns the base64 plaintext.
    // On failure returns a host error envelope so the JS crypto shim throws.
    //
    static func cryptoPrivateDecryptOaepSha1(privateKeyPem: String, dataBase64: String) -> String {
        guard let data = Data(base64Encoded: dataBase64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPrivateDecryptOaepSha1: invalid base64 data"]))
        }

        let pkcs8 = derFromPem(privateKeyPem)
        guard let pkcs1 = unwrapPkcs8(pkcs8: pkcs8) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPrivateDecryptOaepSha1: could not parse PKCS#8 private key"]))
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPrivateDecryptOaepSha1: could not import private key", error))
        }
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, data as CFData, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPrivateDecryptOaepSha1: decryption failed", error))
        }
        return decrypted.base64EncodedString()
    }

    //
    // host.cryptoPublicKeyFromPrivate(privateKeyPem): derives the SPKI PEM public key from a PKCS#8 PEM
    // private key. On failure returns a host error envelope so the JS crypto shim throws.
    //
    static func cryptoPublicKeyFromPrivate(privateKeyPem: String) -> String {
        let pkcs8 = derFromPem(privateKeyPem)
        guard let pkcs1 = unwrapPkcs8(pkcs8: pkcs8) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPublicKeyFromPrivate: could not parse PKCS#8 private key"]))
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPublicKeyFromPrivate: could not import private key", error))
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "cryptoPublicKeyFromPrivate: public key derivation failed"]))
        }
        guard let publicPkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return HostBridge.hostErrorEnvelope(cryptoError("cryptoPublicKeyFromPrivate: public key export failed", error))
        }
        return toPem(type: "PUBLIC KEY", der: wrapSpki(pkcs1Public: [UInt8](publicPkcs1)))
    }

    //
    // Wraps a PKCS#1 RSAPrivateKey DER into a PKCS#8 PrivateKeyInfo DER (version 0, rsaEncryption
    // algorithm, the PKCS#1 key as the private-key OCTET STRING).
    //
    static func wrapPkcs8(pkcs1Private: [UInt8]) -> [UInt8] {
        let version: [UInt8] = [0x02, 0x01, 0x00]
        let privateKeyOctetString = derTagged(tag: 0x04, content: pkcs1Private)
        return derSequence(version + rsaAlgorithmIdentifier + privateKeyOctetString)
    }

    //
    // Wraps a PKCS#1 RSAPublicKey DER into an SPKI SubjectPublicKeyInfo DER (rsaEncryption algorithm,
    // the PKCS#1 key as the public-key BIT STRING with a zero unused-bits prefix).
    //
    static func wrapSpki(pkcs1Public: [UInt8]) -> [UInt8] {
        let bitString = derTagged(tag: 0x03, content: [0x00] + pkcs1Public)
        return derSequence(rsaAlgorithmIdentifier + bitString)
    }

    //
    // Unwraps a PKCS#8 PrivateKeyInfo DER back to the PKCS#1 RSAPrivateKey DER (the private-key OCTET
    // STRING contents), so SecKeyCreateWithData can import it. Returns nil if the structure is not a
    // PKCS#8 RSA private key.
    //
    static func unwrapPkcs8(pkcs8: [UInt8]) -> [UInt8]? {
        var reader = DerReader(bytes: pkcs8)
        guard let sequence = reader.readTagged(0x30) else {
            return nil
        }
        var inner = DerReader(bytes: sequence)

        // version INTEGER
        guard inner.readTagged(0x02) != nil else {
            return nil
        }
        // AlgorithmIdentifier SEQUENCE
        guard inner.readTagged(0x30) != nil else {
            return nil
        }
        // privateKey OCTET STRING (the PKCS#1 RSAPrivateKey)
        return inner.readTagged(0x04)
    }

    //
    // Unwraps an SPKI SubjectPublicKeyInfo DER back to the PKCS#1 RSAPublicKey DER (the BIT STRING
    // contents, minus the leading unused-bits byte), so SecKeyCreateWithData can import it. Returns nil
    // if the structure is not an SPKI RSA public key. The inverse of wrapSpki.
    //
    static func unwrapSpki(spki: [UInt8]) -> [UInt8]? {
        var reader = DerReader(bytes: spki)
        guard let sequence = reader.readTagged(0x30) else {
            return nil
        }
        var inner = DerReader(bytes: sequence)

        // AlgorithmIdentifier SEQUENCE
        guard inner.readTagged(0x30) != nil else {
            return nil
        }
        // subjectPublicKey BIT STRING (a leading 0x00 unused-bits byte, then the PKCS#1 RSAPublicKey)
        guard let bitString = inner.readTagged(0x03), bitString.count > 1, bitString[0] == 0x00 else {
            return nil
        }
        return Array(bitString[1...])
    }

    //
    // Wraps DER bytes as a PEM block of the given type (e.g. "PRIVATE KEY"), with 64-character base64
    // lines, matching CryptoHost.toPem on Android.
    //
    static func toPem(type: String, der: [UInt8]) -> String {
        let base64 = Data(der).base64EncodedString()
        var body = ""
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            body += base64[offset..<end] + "\n"
            offset = end
        }
        return "-----BEGIN \(type)-----\n" + body + "-----END \(type)-----\n"
    }

    //
    // Extracts the raw DER bytes from a PEM block, stripping the BEGIN/END lines and all whitespace.
    //
    static func derFromPem(_ pem: String) -> [UInt8] {
        var base64 = ""
        for line in pem.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("-----") {
                continue
            }
            base64 += line.trimmingCharacters(in: .whitespaces)
        }
        return [UInt8](Data(base64Encoded: base64) ?? Data())
    }

    //
    // DER length octets for a content length, using the definite short or long form as required.
    //
    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var value = length
        var lengthBytes: [UInt8] = []
        while value > 0 {
            lengthBytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(lengthBytes.count)] + lengthBytes
    }

    //
    // Encodes a DER value with the given tag around the content (tag + length + content).
    //
    private static func derTagged(tag: UInt8, content: [UInt8]) -> [UInt8] {
        return [tag] + derLength(content.count) + content
    }

    //
    // Encodes a DER SEQUENCE (tag 0x30) around the content.
    //
    private static func derSequence(_ content: [UInt8]) -> [UInt8] {
        return derTagged(tag: 0x30, content: content)
    }

    //
    // Builds an NSError from a message and an optional CFError captured by a Security call.
    //
    private static func cryptoError(_ message: String, _ error: Unmanaged<CFError>?) -> NSError {
        let detail = error.map { "\($0.takeRetainedValue())" } ?? "unknown error"
        return NSError(domain: "crypto", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(message): \(detail)"])
    }
}

//
// A minimal DER reader that walks tag-length-value fields in order, used to unwrap the PKCS#8 private
// key structure. Only the definite-length forms the RSA structures use are supported.
//
private struct DerReader {

    //
    // The DER bytes being read.
    //
    private let bytes: [UInt8]

    //
    // The current read offset into `bytes`.
    //
    private var offset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    //
    // Reads the next field, returning its content bytes if its tag matches `expectedTag`, or nil on a
    // tag mismatch or a truncated field. Advances past the field on a match.
    //
    mutating func readTagged(_ expectedTag: UInt8) -> [UInt8]? {
        guard offset < bytes.count, bytes[offset] == expectedTag else {
            return nil
        }
        offset += 1

        guard offset < bytes.count else {
            return nil
        }
        var length = 0
        let first = bytes[offset]
        offset += 1
        if first < 0x80 {
            length = Int(first)
        }
        else {
            let count = Int(first & 0x7f)
            guard offset + count <= bytes.count else {
                return nil
            }
            for index in 0..<count {
                length = (length << 8) | Int(bytes[offset + index])
            }
            offset += count
        }

        guard offset + length <= bytes.count else {
            return nil
        }
        let content = Array(bytes[offset..<offset + length])
        offset += length
        return content
    }
}
