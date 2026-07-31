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
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
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

    //
    // The outbound half of the socket layer. This is what makes an `http://` endpoint reachable as
    // plain HTTP with no TLS in the path, so it is covered against a real loopback server socket.
    //
    @Test
    public void connectSendsAndReceivesOverAnOutboundConnection() throws Exception {
        try (ServerSocket peer = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            String connect = tcpHost.tcpConnect("127.0.0.1", peer.getLocalPort());
            assertFalse("connect is not an error envelope", connect.startsWith("@@HOSTERR@@"));
            String connectionId = stringField(connect, "connectionId");
            assertTrue("a connection id was allocated", connectionId.length() > 0);

            Socket accepted = peer.accept();
            accepted.setSoTimeout(3000);

            // Worker -> peer: tcpWrite reaches the remote end.
            byte[] request = "GET / HTTP/1.1\r\n\r\n".getBytes(StandardCharsets.UTF_8);
            assertNull(tcpHost.tcpWrite(connectionId, Base64.getEncoder().encodeToString(request)));

            InputStream acceptedIn = accepted.getInputStream();
            byte[] received = new byte[request.length];
            int offset = 0;
            while (offset < received.length) {
                int read = acceptedIn.read(received, offset, received.length - offset);
                assertTrue("stream did not close early", read != -1);
                offset += read;
            }
            assertEquals("GET / HTTP/1.1\r\n\r\n", new String(received, StandardCharsets.UTF_8));

            // Peer -> worker: the read loop turns inbound bytes into a base64 data event.
            OutputStream acceptedOut = accepted.getOutputStream();
            acceptedOut.write("HTTP/1.1 200 OK\r\n\r\n".getBytes(StandardCharsets.UTF_8));
            acceptedOut.flush();

            String dataEvent = tcpHost.awaitInboundEvent(3000);
            assertNotNull("a data event arrived", dataEvent);
            assertTrue(dataEvent.contains("\"kind\":\"data\""));
            assertEquals(connectionId, stringField(dataEvent, "connectionId"));
            assertEquals("HTTP/1.1 200 OK\r\n\r\n",
                new String(Base64.getDecoder().decode(stringField(dataEvent, "base64")), StandardCharsets.UTF_8));

            // Peer close -> the worker sees a close event for that connection.
            accepted.close();
            String closeEvent = tcpHost.awaitInboundEvent(3000);
            assertNotNull("a close event arrived", closeEvent);
            assertTrue(closeEvent.contains("\"kind\":\"close\""));
            assertEquals(connectionId, stringField(closeEvent, "connectionId"));
        }
    }

    //
    // A refused connection must report the failure rather than hand back a connection id that never
    // carries any bytes.
    //
    @Test
    public void connectToAClosedPortReturnsAnErrorEnvelope() throws Exception {
        ServerSocket peer = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        int closedPort = peer.getLocalPort();
        peer.close();

        String connect = tcpHost.tcpConnect("127.0.0.1", closedPort);

        assertTrue("connect reports an error envelope", connect.startsWith("@@HOSTERR@@"));
    }

    //
    // Closing an outbound connection releases it, so a later write to the same id is a no-op rather
    // than reaching a socket that should be gone.
    //
    @Test
    public void closeReleasesAnOutboundConnection() throws Exception {
        try (ServerSocket peer = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            String connectionId = stringField(tcpHost.tcpConnect("127.0.0.1", peer.getLocalPort()), "connectionId");
            peer.accept();

            assertNull(tcpHost.tcpClose(connectionId));
            assertNull(tcpHost.tcpWrite(connectionId, Base64.getEncoder().encodeToString("x".getBytes(StandardCharsets.UTF_8))));
        }
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
