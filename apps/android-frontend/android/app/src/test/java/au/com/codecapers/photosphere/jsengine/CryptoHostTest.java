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
    public void oaepSha1EncryptDecryptRoundTrips() throws Exception {
        String json = CryptoHost.cryptoGenerateRsaKeyPair(2048);
        String privatePem = extractJsonString(json, "privateKeyPem");
        String publicPem = extractJsonString(json, "publicKeyPem");

        byte[] secret = "an-aes-256-key-placeholder-32byt".getBytes(StandardCharsets.UTF_8);
        String secretBase64 = Base64.getEncoder().encodeToString(secret);

        String encryptedBase64 = CryptoHost.cryptoPublicEncryptOaepSha1(publicPem, secretBase64);
        assertFalse("not an error envelope", encryptedBase64.startsWith("@@HOSTERR@@"));

        String decryptedBase64 = CryptoHost.cryptoPrivateDecryptOaepSha1(privatePem, encryptedBase64);
        assertFalse("not an error envelope", decryptedBase64.startsWith("@@HOSTERR@@"));
        assertEquals(secretBase64, decryptedBase64);
    }

    @Test
    public void oaepSha1DecryptsCiphertextProducedByNodeStyleDefaultPadding() throws Exception {
        // Encrypt with the JCA OAEP-SHA1 transformation directly (what Node's default padding produces)
        // and confirm the host function decrypts it, pinning the padding contract to SHA-1 OAEP.
        String json = CryptoHost.cryptoGenerateRsaKeyPair(2048);
        String privatePem = extractJsonString(json, "privateKeyPem");
        String publicPem = extractJsonString(json, "publicKeyPem");

        byte[] spki = CryptoHost.derFromPem(publicPem);
        PublicKey publicKey = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(spki));
        javax.crypto.Cipher cipher = javax.crypto.Cipher.getInstance("RSA/ECB/OAEPWithSHA-1AndMGF1Padding");
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, publicKey);
        byte[] plaintext = "round-trip via node-style padding".getBytes(StandardCharsets.UTF_8);
        String encryptedBase64 = Base64.getEncoder().encodeToString(cipher.doFinal(plaintext));

        String decryptedBase64 = CryptoHost.cryptoPrivateDecryptOaepSha1(privatePem, encryptedBase64);
        assertFalse("not an error envelope", decryptedBase64.startsWith("@@HOSTERR@@"));
        assertEquals(new String(plaintext, StandardCharsets.UTF_8), new String(Base64.getDecoder().decode(decryptedBase64), StandardCharsets.UTF_8));
    }

    @Test
    public void publicKeyFromPrivateMatchesGeneratedPublicKey() throws Exception {
        String json = CryptoHost.cryptoGenerateRsaKeyPair(2048);
        String privatePem = extractJsonString(json, "privateKeyPem");
        String publicPem = extractJsonString(json, "publicKeyPem");

        String derivedPublicPem = CryptoHost.cryptoPublicKeyFromPrivate(privatePem);
        assertFalse("not an error envelope", derivedPublicPem.startsWith("@@HOSTERR@@"));

        // The derived SPKI DER equals the generated public key's SPKI DER.
        byte[] generatedSpki = CryptoHost.derFromPem(publicPem);
        byte[] derivedSpki = CryptoHost.derFromPem(derivedPublicPem);
        assertEquals(generatedSpki.length, derivedSpki.length);
        for (int index = 0; index < generatedSpki.length; index++) {
            assertEquals(generatedSpki[index], derivedSpki[index]);
        }
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
