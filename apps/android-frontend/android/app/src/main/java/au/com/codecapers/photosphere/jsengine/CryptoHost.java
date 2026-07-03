package au.com.codecapers.photosphere.jsengine;

import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;

//
// The native RSA crypto behind the host.crypto* functions. The embedded engine has no RSA key
// generation or signing (LAN-share's receiver self-signs its TLS certificate in TypeScript, but the
// key generation and the SHA256withRSA signature must come from native crypto). This class provides
// exactly those two operations. It is written against plain java.security (no android.* APIs) so it
// works on the project minSdk and is unit-testable on a plain JVM, matching the HostFunctions
// convention. All methods are static and stateless, so the engine pool can call them concurrently.
//
public final class CryptoHost {

    //
    // Private constructor: static helper class, never instantiated.
    //
    private CryptoHost() {
    }

    //
    // host.cryptoGenerateRsaKeyPair(modulusLength): generates an RSA key pair and returns a JSON string
    // { privateKeyPem, publicKeyPem } (PKCS#8 private, SPKI public, both PEM). On failure returns a host
    // error envelope so the JS crypto shim throws.
    //
    public static String cryptoGenerateRsaKeyPair(int modulusLength) {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(modulusLength);
            KeyPair pair = generator.generateKeyPair();

            String privatePem = toPem("PRIVATE KEY", pair.getPrivate().getEncoded());
            String publicPem = toPem("PUBLIC KEY", pair.getPublic().getEncoded());

            return "{\"privateKeyPem\":\"" + HostFunctions.jsonEscape(privatePem)
                + "\",\"publicKeyPem\":\"" + HostFunctions.jsonEscape(publicPem) + "\"}";
        }
        catch (Exception error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // host.cryptoSignSha256(privateKeyPem, dataBase64): signs the base64-decoded data with SHA256withRSA
    // using the PEM PKCS#8 private key and returns the base64 signature. On failure returns a host error
    // envelope so the JS crypto shim throws.
    //
    public static String cryptoSignSha256(String privateKeyPem, String dataBase64) {
        try {
            byte[] pkcs8 = derFromPem(privateKeyPem);
            KeyFactory keyFactory = KeyFactory.getInstance("RSA");
            PrivateKey privateKey = keyFactory.generatePrivate(new PKCS8EncodedKeySpec(pkcs8));

            Signature signature = Signature.getInstance("SHA256withRSA");
            signature.initSign(privateKey);
            signature.update(HostFunctions.base64Decode(dataBase64));
            return HostFunctions.base64Encode(signature.sign());
        }
        catch (Exception error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Wraps DER bytes as a PEM block of the given type (e.g. "PRIVATE KEY"), 64-character base64 lines.
    // Package-private so unit tests can verify the encoding.
    //
    static String toPem(String type, byte[] der) {
        String base64 = HostFunctions.base64Encode(der);
        StringBuilder builder = new StringBuilder();
        builder.append("-----BEGIN ").append(type).append("-----\n");
        for (int offset = 0; offset < base64.length(); offset += 64) {
            builder.append(base64, offset, Math.min(offset + 64, base64.length())).append("\n");
        }
        builder.append("-----END ").append(type).append("-----\n");
        return builder.toString();
    }

    //
    // Extracts the raw DER bytes from a PEM block, stripping the BEGIN/END lines and all whitespace.
    // Package-private so unit tests can verify round-tripping with toPem.
    //
    static byte[] derFromPem(String pem) {
        String base64 = pem
            .replaceAll("-----BEGIN [A-Z ]+-----", "")
            .replaceAll("-----END [A-Z ]+-----", "")
            .replaceAll("\\s", "");
        return HostFunctions.base64Decode(base64);
    }
}
