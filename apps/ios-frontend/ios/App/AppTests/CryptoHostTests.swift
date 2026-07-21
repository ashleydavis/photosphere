import XCTest
import Security
@testable import App

//
// Tests the native RSA crypto host (host.crypto*) on iOS: key-pair generation returns PKCS#8 / SPKI
// PEM, signing produces a SHA256withRSA signature that verifies against the generated public key, and
// the PEM/DER and PKCS#8 wrapping helpers round-trip. Mirrors the Android CryptoHost test so both
// platforms produce an interchangeable PEM contract.
//
final class CryptoHostTests: XCTestCase {

    //
    // cryptoGenerateRsaKeyPair returns a JSON object with PKCS#8 private and SPKI public PEM blocks.
    //
    func testGenerateReturnsPemPair() throws {
        let json = CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048)
        XCTAssertFalse(json.hasPrefix("@@HOSTERR@@"), "key generation should not error: \(json)")

        let parsed = try parse(json)
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        XCTAssertTrue(privatePem.contains("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(privatePem.contains("-----END PRIVATE KEY-----"))
        XCTAssertTrue(publicPem.contains("-----BEGIN PUBLIC KEY-----"))
        XCTAssertTrue(publicPem.contains("-----END PUBLIC KEY-----"))
    }

    //
    // A signature produced by cryptoSignSha256 verifies against the public key from the same pair,
    // proving the private key was imported and signed correctly.
    //
    func testSignatureVerifiesWithGeneratedPublicKey() throws {
        let parsed = try parse(CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048))
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        let message = Data("photosphere-lan-share".utf8)
        let signatureBase64 = CryptoHost.cryptoSignSha256(privateKeyPem: privatePem, dataBase64: message.base64EncodedString())
        XCTAssertFalse(signatureBase64.hasPrefix("@@HOSTERR@@"), "signing should not error: \(signatureBase64)")
        let signature = try XCTUnwrap(Data(base64Encoded: signatureBase64))

        let publicKey = try makePublicKey(spkiPem: publicPem)
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, &error)
        XCTAssertTrue(verified, "signature must verify against the generated public key")
    }

    //
    // A signature over one message must not verify against a different message.
    //
    func testSignatureRejectsTamperedMessage() throws {
        let parsed = try parse(CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048))
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        let signed = Data("original".utf8)
        let signatureBase64 = CryptoHost.cryptoSignSha256(privateKeyPem: privatePem, dataBase64: signed.base64EncodedString())
        let signature = try XCTUnwrap(Data(base64Encoded: signatureBase64))

        let publicKey = try makePublicKey(spkiPem: publicPem)
        let tampered = Data("tampered".utf8)
        let verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, tampered as CFData, signature as CFData, nil)
        XCTAssertFalse(verified, "a signature must not verify against a different message")
    }

    //
    // toPem then derFromPem returns the original DER bytes (the PEM body is the base64 of the DER).
    //
    func testPemRoundTrip() {
        let der: [UInt8] = Array(0...200).map { UInt8($0 & 0xff) }
        let pem = CryptoHost.toPem(type: "PRIVATE KEY", der: der)
        let decoded = CryptoHost.derFromPem(pem)
        XCTAssertEqual(decoded, der)
    }

    //
    // Wrapping a PKCS#1 private key into PKCS#8 and unwrapping it returns the original PKCS#1 bytes.
    //
    func testPkcs8WrapUnwrapRoundTrip() throws {
        // Generate a key and export its PKCS#1 (SecKey external representation for RSA is PKCS#1).
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)

        let pkcs8 = CryptoHost.wrapPkcs8(pkcs1Private: [UInt8](pkcs1))
        let unwrapped = try XCTUnwrap(CryptoHost.unwrapPkcs8(pkcs8: pkcs8))
        XCTAssertEqual(unwrapped, [UInt8](pkcs1))
    }

    //
    // cryptoPublicEncryptOaepSha1 / cryptoPrivateDecryptOaepSha1 round-trip an AES key through OAEP-SHA1.
    //
    func testOaepSha1EncryptDecryptRoundTrips() throws {
        let parsed = try parse(CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048))
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        let secret = Data("an-aes-256-key-placeholder-32byt".utf8)
        let encrypted = CryptoHost.cryptoPublicEncryptOaepSha1(publicKeyPem: publicPem, dataBase64: secret.base64EncodedString())
        XCTAssertFalse(encrypted.hasPrefix("@@HOSTERR@@"), "encryption should not error: \(encrypted)")

        let decrypted = CryptoHost.cryptoPrivateDecryptOaepSha1(privateKeyPem: privatePem, dataBase64: encrypted)
        XCTAssertFalse(decrypted.hasPrefix("@@HOSTERR@@"), "decryption should not error: \(decrypted)")
        XCTAssertEqual(decrypted, secret.base64EncodedString())
    }

    //
    // cryptoPrivateDecryptOaepSha1 decrypts ciphertext produced with .rsaEncryptionOAEPSHA1 directly
    // (the same padding Node's default publicEncrypt uses), pinning the SHA-1 OAEP contract.
    //
    func testOaepSha1DecryptsSecKeyOaepSha1Ciphertext() throws {
        let parsed = try parse(CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048))
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        let publicKey = try makePublicKey(spkiPem: publicPem)
        let plaintext = Data("padding contract check".utf8)
        let encrypted = try XCTUnwrap(SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA1, plaintext as CFData, nil) as Data?)

        let decrypted = CryptoHost.cryptoPrivateDecryptOaepSha1(privateKeyPem: privatePem, dataBase64: encrypted.base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: decrypted), plaintext)
    }

    //
    // cryptoPublicKeyFromPrivate derives the SPKI public key that matches the generated public key.
    //
    func testPublicKeyFromPrivateMatchesGenerated() throws {
        let parsed = try parse(CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: 2048))
        let privatePem = try XCTUnwrap(parsed["privateKeyPem"] as? String)
        let publicPem = try XCTUnwrap(parsed["publicKeyPem"] as? String)

        let derived = CryptoHost.cryptoPublicKeyFromPrivate(privateKeyPem: privatePem)
        XCTAssertFalse(derived.hasPrefix("@@HOSTERR@@"), "derivation should not error: \(derived)")
        XCTAssertEqual(CryptoHost.derFromPem(derived), CryptoHost.derFromPem(publicPem))
    }

    //
    // Parses a host-function JSON result object into a dictionary.
    //
    private func parse(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    //
    // Reconstructs a SecKey public key from an SPKI PEM (unwrapping the SPKI to the PKCS#1 the SecKey
    // importer expects), for verifying signatures in the tests.
    //
    private func makePublicKey(spkiPem: String) throws -> SecKey {
        let spki = CryptoHost.derFromPem(spkiPem)
        let pkcs1 = try XCTUnwrap(unwrapSpki(spki: spki))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        return try XCTUnwrap(SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, nil))
    }

    //
    // Unwraps an SPKI SubjectPublicKeyInfo to the PKCS#1 RSAPublicKey (the BIT STRING contents, minus the
    // leading zero unused-bits octet), the inverse of CryptoHost.wrapSpki, for test verification.
    //
    private func unwrapSpki(spki: [UInt8]) -> [UInt8]? {
        // SEQUENCE { AlgorithmIdentifier SEQUENCE, BIT STRING }
        guard spki.count > 2, spki[0] == 0x30 else {
            return nil
        }
        var index = 2
        if spki[1] & 0x80 != 0 {
            index = 2 + Int(spki[1] & 0x7f)
        }
        // Skip the AlgorithmIdentifier SEQUENCE.
        guard index < spki.count, spki[index] == 0x30 else {
            return nil
        }
        let algLengthByte = spki[index + 1]
        var algHeader = 2
        var algLength = Int(algLengthByte)
        if algLengthByte & 0x80 != 0 {
            let count = Int(algLengthByte & 0x7f)
            algHeader = 2 + count
            algLength = 0
            for offset in 0..<count {
                algLength = (algLength << 8) | Int(spki[index + 2 + offset])
            }
        }
        index += algHeader + algLength
        // Now at the BIT STRING.
        guard index < spki.count, spki[index] == 0x03 else {
            return nil
        }
        let bitLengthByte = spki[index + 1]
        var bitHeader = 2
        var bitLength = Int(bitLengthByte)
        if bitLengthByte & 0x80 != 0 {
            let count = Int(bitLengthByte & 0x7f)
            bitHeader = 2 + count
            bitLength = 0
            for offset in 0..<count {
                bitLength = (bitLength << 8) | Int(spki[index + 2 + offset])
            }
        }
        // BIT STRING content starts with a leading unused-bits octet (0x00); the PKCS#1 follows.
        let contentStart = index + bitHeader + 1
        let contentEnd = index + bitHeader + bitLength
        guard contentStart <= contentEnd, contentEnd <= spki.count else {
            return nil
        }
        return Array(spki[contentStart..<contentEnd])
    }
}
