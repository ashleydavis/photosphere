package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

//
// Plain-JVM unit tests for the native UDP host. Real DatagramSockets on loopback exercise the bind,
// send, and receive paths with no Android stubs and no device (java.net is a full JDK here).
//
public final class UdpHostTest {

    //
    // The host under test; shut down after each test to release sockets.
    //
    private final UdpHost udpHost = new UdpHost();

    @After
    public void tearDown() {
        udpHost.shutdown();
    }

    //
    // Reads the numeric "port" out of the { socketId, port } JSON udpBind returns.
    //
    private static int portOf(String bindJson) {
        int marker = bindJson.indexOf("\"port\":");
        String rest = bindJson.substring(marker + "\"port\":".length());
        int end = rest.indexOf("}");
        return Integer.parseInt(rest.substring(0, end).trim());
    }

    @Test
    public void bindSendAndReceiveDeliversAMessageEvent() throws Exception {
        String receiverBind = udpHost.udpBind("127.0.0.1", 0, true);
        assertFalse("bind is not an error envelope", receiverBind.startsWith("@@HOSTERR@@"));
        int receiverPort = portOf(receiverBind);

        String senderBind = udpHost.udpBind("127.0.0.1", 0, true);
        assertFalse(senderBind.startsWith("@@HOSTERR@@"));
        String senderId = senderBind.substring(senderBind.indexOf("\"socketId\":\"") + "\"socketId\":\"".length(), senderBind.indexOf("\",\"port\""));

        byte[] payload = "PSIE_RECV:5555:abcdef".getBytes(StandardCharsets.UTF_8);
        String sendResult = udpHost.udpSend(senderId, Base64.getEncoder().encodeToString(payload), "127.0.0.1", receiverPort);
        // udpSend returns null on success.
        assertTrue(sendResult == null || !sendResult.startsWith("@@HOSTERR@@"));

        String event = udpHost.awaitInboundEvent(3000);
        assertNotNull("a message event arrived", event);
        assertTrue(event.contains("\"kind\":\"message\""));
        assertTrue(event.contains("\"address\":\"127.0.0.1\""));

        // The base64 payload in the event decodes back to what was sent.
        int base64Start = event.indexOf("\"base64\":\"") + "\"base64\":\"".length();
        int base64End = event.indexOf("\"", base64Start);
        String base64 = event.substring(base64Start, base64End);
        String decoded = new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8);
        assertTrue(decoded.equals("PSIE_RECV:5555:abcdef"));
    }

    @Test
    public void hasLiveSocketsReflectsOpenSockets() {
        assertFalse(udpHost.hasLiveSockets());
        String bind = udpHost.udpBind("127.0.0.1", 0, false);
        String socketId = bind.substring(bind.indexOf("\"socketId\":\"") + "\"socketId\":\"".length(), bind.indexOf("\",\"port\""));
        assertTrue(udpHost.hasLiveSockets());
        udpHost.udpClose(socketId);
        assertFalse(udpHost.hasLiveSockets());
    }
}
