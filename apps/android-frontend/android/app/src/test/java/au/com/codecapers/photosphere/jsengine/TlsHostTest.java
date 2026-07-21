package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.util.Base64;

//
// Plain-JVM unit tests for the native TLS host. A self-signed cert/key fixture drives a real TLS
// handshake over loopback (javax.net.ssl is a full JDK here), verifying the server binds, the client
// captures the server certificate for pinning, and bytes flow both ways.
//
public final class TlsHostTest {

    //
    // A self-signed test certificate (X.509) and its PKCS#8 private key, generated with openssl. Used to
    // stand up the TLS server; the client pins against this certificate's DER.
    //
    private static final String CERT_PEM =
        "-----BEGIN CERTIFICATE-----\n"
        + "MIIDFzCCAf+gAwIBAgIUYU8J9RPPA/CpNQg3JchlvGfCqZkwDQYJKoZIhvcNAQEL\n"
        + "BQAwGzEZMBcGA1UEAwwQcGhvdG9zcGhlcmUtdGVzdDAeFw0yNjA3MDIyMjI4NTVa\n"
        + "Fw0zNjA2MjkyMjI4NTVaMBsxGTAXBgNVBAMMEHBob3Rvc3BoZXJlLXRlc3QwggEi\n"
        + "MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCuThnn2bsC2PgVHyfQgnPKABzC\n"
        + "vSUr+YOkl7kdwnxhY5dexwTkoO/NZl030omIt+0WjF0+maR8bDQl54kllLBk0c/W\n"
        + "WaSsF7cq4qgBh2UiZl5hlyr23F8YpkG0tGroZMwE0kLei3j5/ACPvGMbsxiw4uhL\n"
        + "mWkBOzcXOO4d6DzDHs+64hupfTaFOKWue3wt2nD3nkQaNvaYFCrSTwoIb3U6T/W3\n"
        + "jUcBtl1jKwCzaAXVjgstAw+DmpravqhkGA/MLb0p9Wd6Hyqo2Yfr53Mb6L4yrtHV\n"
        + "1JXyAfzOEOAzfJX1bOpsW/Z+8g1re5PrkZzv5BgGgE9BbZ2hmP9kyqewek1TAgMB\n"
        + "AAGjUzBRMB0GA1UdDgQWBBQrxsCN6Kjjy0Twatzj+BYMBhYgGTAfBgNVHSMEGDAW\n"
        + "gBQrxsCN6Kjjy0Twatzj+BYMBhYgGTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3\n"
        + "DQEBCwUAA4IBAQCbD/T2x4y+jhzA1ASMlv3Ep3iURmJAhLLjdvyCG5fhFU4oCNa+\n"
        + "LMzDMgQRL59PJItJ/gojrI6AC2vTQWy1Q0lKy9PZhLUPtb/IFF2NURvcpmNzEwps\n"
        + "oM/AEMvrvRnRSjBE+8p1Gyiwd7f5cEB9IAQfzzTuQncvsOOlXGnX0l0QLp2t9vdF\n"
        + "1phhljfVe+zlND/Y3MisctV8thDvrDgKCSiYQVDID/XvwSgzoecT6pLfpYdQIjUn\n"
        + "tf6tBcbswg4ArpizbxQ9eK1lfgxsDzw0x2vGESCMfBxW6rnFMRvwaD3mLTGhhhgJ\n"
        + "7fGMmwZGctXi+woaXwWGAaJc+3k9D27WlO1p\n"
        + "-----END CERTIFICATE-----\n";

    //
    // The PKCS#8 private key for CERT_PEM.
    //
    private static final String KEY_PEM =
        "-----BEGIN PRIVATE KEY-----\n"
        + "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCuThnn2bsC2PgV\n"
        + "HyfQgnPKABzCvSUr+YOkl7kdwnxhY5dexwTkoO/NZl030omIt+0WjF0+maR8bDQl\n"
        + "54kllLBk0c/WWaSsF7cq4qgBh2UiZl5hlyr23F8YpkG0tGroZMwE0kLei3j5/ACP\n"
        + "vGMbsxiw4uhLmWkBOzcXOO4d6DzDHs+64hupfTaFOKWue3wt2nD3nkQaNvaYFCrS\n"
        + "TwoIb3U6T/W3jUcBtl1jKwCzaAXVjgstAw+DmpravqhkGA/MLb0p9Wd6Hyqo2Yfr\n"
        + "53Mb6L4yrtHV1JXyAfzOEOAzfJX1bOpsW/Z+8g1re5PrkZzv5BgGgE9BbZ2hmP9k\n"
        + "yqewek1TAgMBAAECggEAS2tl0Ckovvmslk8Nxi279iqIR0baP6XN7TjtE1Bkyyrx\n"
        + "g0Pv/REZ0bE6In5JnkufHYOMkRqfzmpvQftmH0mv7V/PYzsUgpYcXkUGVusDupe6\n"
        + "vNVQ9NGzoBHIGm16WKXMlUV5Q5vrs5bzkz37UC/1PgxgYN23Tp4Vn0m11mD3caE6\n"
        + "vednXo8caA0SteJcmYBBJNbhpPyGP13NiSCt+NG8r9f2cLeQT87nuZcfS4QkCDbO\n"
        + "R9rz7cMcEgMmfRK3Ofty5d9O8R3jg2Y6QOEEeCQgdoX55nMrYO/v1JwW91QVxYxv\n"
        + "T/u8kW4KuELx4c3wFUv8w8EbEvrirHwM8zhSfvg7oQKBgQDn3XRA+eo9ro72i0Cj\n"
        + "md/0CbSP/GAPtAtmiOqwSQRee3xi7AjBCKstTtXyEUDEsFUe89HlFFZl14DlivaH\n"
        + "CvloYbFZ6ZfqNXYbUZ+KxRArGZRLlpQPk12bRr1vI22QQmhsT51gK8523DbHOwiE\n"
        + "wPUpIzHDBzkEEscaIbAGaBF+kQKBgQDActZNiYktXpuA8WexB1hvG2T9wdO7JvvN\n"
        + "xDZvPQGKcupNgDeWq7pidXaWV4RX/c8DglCTRHl7OruczZ5nQ7QaIEaJjEJ9nsTh\n"
        + "yCzwQ6Eqc5W2mtslDv8VvFZvBMhVhFeadvVYNlpgTyN8YYa4n1ilyJOqcUZuykLY\n"
        + "zSdqdrTHowKBgBmmY//0JbehIeugSAxRL3c9w53SG4ZhMomrR9ssmLEjFAWVevpv\n"
        + "zQ/8Eqruwa2AnEoKSwP+lfg6OOYr003pJuInPIln0Ah21ZP8GZwuZLV/5OnfxI1c\n"
        + "jhRpZPdwgeRdlFO3Ev/amMKJZf3wR+b3uadNX2nl2KbctO3tIB31UUohAoGBAKIz\n"
        + "6CYgBuujcsOCNFhEDahP2ZX7eP6jw9XRS+QD8jmD07GQoMmwYf68bEAY8WXMeV/G\n"
        + "xSzqqM1RWnG16I22xaTDkVA7VItWdzCprB6xkbQbCZOH/67DbgIe5GbcDBHv4npB\n"
        + "S1aXMSM9cHZUKN2RCIFqhfNBWBDnDuJ2P4N/G62rAoGBAMv91A0gTrH0aKKbL+aw\n"
        + "6KPtrEluBmzdkn45/llIrBRdRzYB1ZfgaWbdtj2hp5nL9BN5F5raujDrV37/3bIt\n"
        + "S41cFN9CWGP7qzQ/esJ40ONQWFL2mGJUPurjzufZKtfXwxeF4PKlBQcRSCluHbbx\n"
        + "bFHoIJHjitvKY+dbwdXioGqE\n"
        + "-----END PRIVATE KEY-----\n";

    //
    // The host under test; shut down after each test to release sockets.
    //
    private final TlsHost tlsHost = new TlsHost();

    @After
    public void tearDown() {
        tlsHost.shutdown();
    }

    //
    // Reads a string field out of one of the small JSON envelopes the host returns/enqueues.
    //
    private static String jsonString(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int start = json.indexOf(marker);
        if (start < 0) {
            return null;
        }
        start += marker.length();
        int end = json.indexOf("\"", start);
        return json.substring(start, end);
    }

    //
    // Reads the numeric port field out of the { listenerId, port } envelope.
    //
    private static int portOf(String json) {
        int marker = json.indexOf("\"port\":");
        String rest = json.substring(marker + "\"port\":".length());
        int end = rest.indexOf("}");
        return Integer.parseInt(rest.substring(0, end).trim());
    }

    //
    // Polls for the next "data" event on the given connection within the timeout, returning the decoded
    // payload string, or null if none arrives.
    //
    private String awaitData(String connectionId, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            String event = tlsHost.awaitInboundEvent(deadline - System.currentTimeMillis());
            if (event == null) {
                continue;
            }
            if (event.contains("\"kind\":\"data\"") && event.contains("\"connectionId\":\"" + connectionId + "\"")) {
                String base64 = jsonString(event, "base64");
                return new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8);
            }
        }
        return null;
    }

    @Test
    public void handshakePinningAndBidirectionalData() throws Exception {
        String listenJson = tlsHost.tlsListen("127.0.0.1", 0, CERT_PEM, KEY_PEM);
        assertFalse("listen is not an error envelope: " + listenJson, listenJson.startsWith("@@HOSTERR@@"));
        int port = portOf(listenJson);

        String connectJson = tlsHost.tlsConnect("127.0.0.1", port, "pinned");
        assertFalse("connect is not an error envelope: " + connectJson, connectJson.startsWith("@@HOSTERR@@"));
        String clientConnId = jsonString(connectJson, "connectionId");
        String peerCertBase64 = jsonString(connectJson, "peerCertBase64");

        // The pinned peer certificate DER matches the server's certificate exactly.
        CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
        byte[] expectedDer = certificateFactory
            .generateCertificate(new ByteArrayInputStream(CERT_PEM.getBytes(StandardCharsets.UTF_8)))
            .getEncoded();
        assertEquals(Base64.getEncoder().encodeToString(expectedDer), peerCertBase64);

        // The server-accepted connection arrives as a "connection" event.
        String serverConnId = null;
        long deadline = System.currentTimeMillis() + 3000;
        while (serverConnId == null && System.currentTimeMillis() < deadline) {
            String event = tlsHost.awaitInboundEvent(deadline - System.currentTimeMillis());
            if (event != null && event.contains("\"kind\":\"connection\"")) {
                serverConnId = jsonString(event, "connectionId");
            }
        }
        assertNotNull("server accepted the connection", serverConnId);

        // Client -> server bytes arrive as a data event on the server connection.
        tlsHost.tlsWrite(clientConnId, Base64.getEncoder().encodeToString("PING".getBytes(StandardCharsets.UTF_8)));
        assertEquals("PING", awaitData(serverConnId, 3000));

        // Server -> client bytes arrive as a data event on the client connection.
        tlsHost.tlsWrite(serverConnId, Base64.getEncoder().encodeToString("PONG".getBytes(StandardCharsets.UTF_8)));
        assertEquals("PONG", awaitData(clientConnId, 3000));

        assertTrue(tlsHost.hasLiveListeners());
        // Both the client and server connections are open, so the engine keeps a client-request task alive.
        assertTrue(tlsHost.hasLiveConnections());
    }

    @Test
    public void validatedModeRejectsASelfSignedCertificate() throws Exception {
        // The self-signed server certificate is not in the system trust store, so a "validated" connect
        // must fail (fail-closed). This is the native half of the S3 bad-certificate test.
        String listenJson = tlsHost.tlsListen("127.0.0.1", 0, CERT_PEM, KEY_PEM);
        assertFalse("listen is not an error envelope: " + listenJson, listenJson.startsWith("@@HOSTERR@@"));
        int port = portOf(listenJson);

        String connectJson = tlsHost.tlsConnect("127.0.0.1", port, "validated");
        assertTrue("validated connect to a self-signed server must fail: " + connectJson, connectJson.startsWith("@@HOSTERR@@"));
    }

    @Test
    public void unknownModeIsAnError() {
        String connectJson = tlsHost.tlsConnect("127.0.0.1", 1, "trust-all");
        assertTrue("an unknown TLS mode must be an error envelope: " + connectJson, connectJson.startsWith("@@HOSTERR@@"));
    }
}
