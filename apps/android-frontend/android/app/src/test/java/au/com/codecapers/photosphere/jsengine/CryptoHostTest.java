package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;

//
// Plain-JVM unit tests for the native RSA crypto host functions. RSA key generation and SHA256withRSA
// signing come from java.security, so they run here with no Android stubs and no device. The generated
// PEMs are checked for parseability and the signature is verified against the generated public key.
//
public final class CryptoHostTest {

    //
    // Parses the { "privateKeyPem": ..., "publicKeyPem": ... } JSON by hand (the values contain escaped
    // newlines) to avoid an Android-only JSON dependency in this plain-JVM test.
    //
    private static String extractJsonString(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int start = json.indexOf(marker);
        assertTrue("key present: " + key, start >= 0);
        start += marker.length();
        StringBuilder value = new StringBuilder();
        for (int index = start; index < json.length(); index++) {
            char character = json.charAt(index);
            if (character == '\\') {
                char next = json.charAt(index + 1);
                if (next == 'n') {
                    value.append('\n');
                }
                else {
                    value.append(next);
                }
                index++;
            }
            else if (character == '"') {
                break;
            }
            else {
                value.append(character);
            }
        }
        return value.toString();
    }

    @Test
    public void generatesParseablePemAndSignsVerifiably() throws Exception {
        String json = CryptoHost.cryptoGenerateRsaKeyPair(2048);
        assertFalse("not an error envelope", json.startsWith("@@HOSTERR@@"));

        String privatePem = extractJsonString(json, "privateKeyPem");
        String publicPem = extractJsonString(json, "publicKeyPem");
        assertTrue(privatePem.contains("BEGIN PRIVATE KEY"));
        assertTrue(publicPem.contains("BEGIN PUBLIC KEY"));

        // The public PEM parses back into an RSA public key (SPKI).
        byte[] spki = CryptoHost.derFromPem(publicPem);
        PublicKey publicKey = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(spki));

        // Sign some data, then verify the signature against the generated public key.
        byte[] data = "the-bytes-to-be-signed".getBytes(StandardCharsets.UTF_8);
        String signatureBase64 = CryptoHost.cryptoSignSha256(privatePem, Base64.getEncoder().encodeToString(data));
        assertFalse("not an error envelope", signatureBase64.startsWith("@@HOSTERR@@"));

        Signature verifier = Signature.getInstance("SHA256withRSA");
        verifier.initVerify(publicKey);
        verifier.update(data);
        assertTrue("signature verifies", verifier.verify(Base64.getDecoder().decode(signatureBase64)));
    }

    @Test
    public void toPemAndDerFromPemRoundTrip() {
        byte[] original = new byte[] { 0, 1, 2, (byte) 250, (byte) 255, 42, 7 };
        String pem = CryptoHost.toPem("PRIVATE KEY", original);
        byte[] roundTripped = CryptoHost.derFromPem(pem);
        assertEquals(original.length, roundTripped.length);
        for (int index = 0; index < original.length; index++) {
            assertEquals(original[index], roundTripped[index]);
        }
    }
}
