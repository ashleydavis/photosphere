package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Test;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

//
// Plain-JVM unit tests for the native TCP host. Real loopback sockets (java.net is a full JDK here,
// and TcpHost uses the portable HostFunctions base64 codec rather than android.util.Base64) exercise
// the listen, accept, inbound-data, outbound-write, and close paths with no Android stubs and no
// device.
//
public final class TcpHostTest {

    //
    // The host under test; shut down after each test to release listeners and connections.
    //
    private final TcpHost tcpHost = new TcpHost();

    @After
    public void tearDown() {
        tcpHost.shutdown();
    }

    //
    // Extracts a string field's value from one of the flat JSON envelopes TcpHost emits.
    //
    private static String stringField(String json, String field) {
        String marker = "\"" + field + "\":\"";
        int start = json.indexOf(marker) + marker.length();
        int end = json.indexOf("\"", start);
        return json.substring(start, end);
    }

    //
    // Extracts an integer field's value from one of the flat JSON envelopes TcpHost emits.
    //
    private static int intField(String json, String field) {
        String marker = "\"" + field + "\":";
        int start = json.indexOf(marker) + marker.length();
        int end = start;
        while (end < json.length() && (Character.isDigit(json.charAt(end)) || json.charAt(end) == '-')) {
            end++;
        }
        return Integer.parseInt(json.substring(start, end));
    }

    @Test
    public void listenAcceptDataAndCloseFlowThroughEvents() throws Exception {
        String listen = tcpHost.tcpListen("127.0.0.1", 0);
        assertFalse("listen is not an error envelope", listen.startsWith("@@HOSTERR@@"));
        int port = intField(listen, "port");
        assertTrue("bound to an OS-assigned port", port > 0);

        Socket client = new Socket();
        client.connect(new InetSocketAddress("127.0.0.1", port), 2000);
        client.setSoTimeout(3000);

        // The accept loop enqueues a connection event before starting the read thread.
        String connectionEvent = tcpHost.awaitInboundEvent(3000);
        assertNotNull("a connection event arrived", connectionEvent);
        assertTrue(connectionEvent.contains("\"kind\":\"connection\""));
        String connectionId = stringField(connectionEvent, "connectionId");

        // Client -> server: bytes arrive as a base64 data event.
        byte[] fromClient = "hello-from-client".getBytes(StandardCharsets.UTF_8);
        OutputStream clientOut = client.getOutputStream();
        clientOut.write(fromClient);
        clientOut.flush();

        String dataEvent = tcpHost.awaitInboundEvent(3000);
        assertNotNull("a data event arrived", dataEvent);
        assertTrue(dataEvent.contains("\"kind\":\"data\""));
        assertEquals(connectionId, stringField(dataEvent, "connectionId"));
        String base64 = stringField(dataEvent, "base64");
        assertEquals("hello-from-client", new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8));

        // Server -> client: tcpWrite reaches the client socket.
        byte[] fromServer = "hello-from-server".getBytes(StandardCharsets.UTF_8);
        String writeResult = tcpHost.tcpWrite(connectionId, Base64.getEncoder().encodeToString(fromServer));
        assertNull("tcpWrite returns null on success", writeResult);

        InputStream clientIn = client.getInputStream();
        byte[] received = new byte[fromServer.length];
        int offset = 0;
        while (offset < received.length) {
            int read = clientIn.read(received, offset, received.length - offset);
            assertTrue("stream did not close early", read != -1);
            offset += read;
        }
        assertEquals("hello-from-server", new String(received, StandardCharsets.UTF_8));

        // Client close -> server emits a close event for the connection.
        client.close();
        String closeEvent = tcpHost.awaitInboundEvent(3000);
        assertNotNull("a close event arrived", closeEvent);
        assertTrue(closeEvent.contains("\"kind\":\"close\""));
        assertEquals(connectionId, stringField(closeEvent, "connectionId"));
    }

    @Test
    public void hasLiveListenersReflectsOpenListeners() throws Exception {
        assertFalse(tcpHost.hasLiveListeners());
        String listen = tcpHost.tcpListen("127.0.0.1", 0);
        String listenerId = stringField(listen, "listenerId");
        assertTrue(tcpHost.hasLiveListeners());
        tcpHost.tcpStopListening(listenerId);
        assertFalse(tcpHost.hasLiveListeners());
    }

    @Test
    public void tcpWriteToUnknownConnectionReturnsNull() {
        assertNull(tcpHost.tcpWrite("C999", Base64.getEncoder().encodeToString("x".getBytes(StandardCharsets.UTF_8))));
    }

    @Test
    public void pollInboundEventReturnsNullWhenIdle() {
        assertNull(tcpHost.pollInboundEvent());
    }
}
