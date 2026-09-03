package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

//
// Plain-JVM tests for the native TCP socket layer, run against real loopback sockets rather than a
// stand-in for one: what is being tested is what the operating system does with a file descriptor,
// which nothing but a real socket can show.
//
public final class TcpHostTest {

    //
    // Reads the connection id out of the JSON tcpConnect answers with.
    //
    private static String connectionIdFrom(String json) {
        int start = json.indexOf("\"connectionId\":\"");
        assertTrue("tcpConnect must answer with a connection id, said: " + json, start >= 0);
        start += "\"connectionId\":\"".length();
        int end = json.indexOf('"', start);
        return json.substring(start, end);
    }

    @Test
    public void aConnectionTheRemoteClosesIsClosedOnThisSideToo() throws Exception {
        // A socket the remote has closed and this side has not sits in CLOSE_WAIT and holds its file
        // descriptor for as long as the process lives. Nothing else closes it: the JS net shim marks
        // its own Socket closed when the close event arrives and never calls back down. Measured on a
        // Pixel 6 syncing a real photo library to S3, the app was holding 646 of them, and once they
        // had built up every upload timed out and no further file reached the bucket.
        //
        // The server here half-closes, sending FIN without closing its own end, so that whether this
        // side closes its socket is something the test can actually observe: the server's own read
        // returns -1 only once the client end is closed.
        ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        TcpHost host = new TcpHost();

        final CountDownLatch serverSawTheClose = new CountDownLatch(1);
        final AtomicInteger serverReadResult = new AtomicInteger(Integer.MIN_VALUE);

        Thread serverThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Socket accepted = server.accept();
                    accepted.setSoTimeout(10000);

                    // FIN to the client, with this end still open for reading.
                    accepted.shutdownOutput();

                    InputStream input = accepted.getInputStream();
                    serverReadResult.set(input.read());
                    serverSawTheClose.countDown();

                    accepted.close();
                }
                catch (IOException error) {
                    // A read that fails rather than returning -1 still means the client end went
                    // away, which is what this is watching for.
                    serverReadResult.set(-1);
                    serverSawTheClose.countDown();
                }
            }
        }, "tcp-host-test-server");
        serverThread.setDaemon(true);
        serverThread.start();

        try {
            String connectResult = host.tcpConnect("127.0.0.1", server.getLocalPort());
            String connectionId = connectionIdFrom(connectResult);

            assertTrue("the server must have seen this side close its socket, and did not within ten seconds",
                serverSawTheClose.await(10, TimeUnit.SECONDS));
            assertEquals("the server's read must have ended rather than returned data", -1, serverReadResult.get());

            // The engine is still told about the close, because the JS net shim ends its own socket
            // and emits `end` and `close` on the strength of this event.
            String event = host.awaitInboundEvent(5000);
            assertNotNull("a close event must still reach the engine", event);
            assertTrue("the close event must name the connection, said: " + event,
                event.contains("\"kind\":\"close\"") && event.contains(connectionId));
        }
        finally {
            host.shutdown();
            server.close();
        }
    }

    @Test
    public void aFileIsSentToTheRemoteWithoutItsBytesEnteringTheEngine() throws Exception {
        // This is what makes uploading from a phone possible. Every other write crosses the bridge as
        // base64, a third larger than the bytes it carries and decoded in an interpreter on the other
        // side; an upload paid that twice, once to read the file and once to send it, and a Pixel 6
        // managed about three megabytes a minute with the network idle nine tenths of the time.
        File storageRoot = java.nio.file.Files.createTempDirectory("psphere-tcp-file").toFile();
        File sourceFile = new File(storageRoot, "photo.jpg");

        byte[] contents = new byte[300 * 1024];
        for (int index = 0; index < contents.length; index++) {
            contents[index] = (byte)(index % 251);
        }
        java.nio.file.Files.write(sourceFile.toPath(), contents);

        ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        TcpHost host = new TcpHost();

        final CountDownLatch received = new CountDownLatch(1);
        final byte[] readBack = new byte[contents.length];

        Thread serverThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Socket accepted = server.accept();
                    accepted.setSoTimeout(10000);
                    InputStream input = accepted.getInputStream();
                    int filled = 0;
                    while (filled < readBack.length) {
                        int bytesRead = input.read(readBack, filled, readBack.length - filled);
                        if (bytesRead == -1) {
                            break;
                        }
                        filled += bytesRead;
                    }
                    received.countDown();
                    accepted.close();
                }
                catch (IOException ignored) {
                    received.countDown();
                }
            }
        }, "tcp-host-test-file-receiver");
        serverThread.setDaemon(true);
        serverThread.start();

        try {
            String connectionId = connectionIdFrom(host.tcpConnect("127.0.0.1", server.getLocalPort()));

            assertEquals("sending a file must succeed", null,
                host.tcpWriteFile(storageRoot, connectionId, "photo.jpg", 0, contents.length));

            assertTrue("the remote must have received the file", received.await(10, TimeUnit.SECONDS));
            assertArrayEquals("the bytes the remote received must be the file's own", contents, readBack);
        }
        finally {
            host.shutdown();
            server.close();
        }
    }

    @Test
    public void sendingAFileFromOutsideTheSandboxIsRefused() throws Exception {
        File storageRoot = java.nio.file.Files.createTempDirectory("psphere-tcp-sandbox").toFile();

        ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        TcpHost host = new TcpHost();

        Thread serverThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    server.accept();
                }
                catch (IOException ignored) {
                }
            }
        }, "tcp-host-test-sandbox");
        serverThread.setDaemon(true);
        serverThread.start();

        try {
            String connectionId = connectionIdFrom(host.tcpConnect("127.0.0.1", server.getLocalPort()));

            String result = host.tcpWriteFile(storageRoot, connectionId, "../outside.txt", 0, 10);

            assertTrue("a path outside the sandbox must be refused, said: " + result,
                result != null && result.length() > 0);
        }
        finally {
            host.shutdown();
            server.close();
        }
    }

    @Test
    public void bytesWrittenReachTheRemoteAndBytesSentBackReachTheEngine() throws Exception {
        // The close above must not be bought at the price of a connection that no longer carries
        // anything, so this covers the ordinary round trip on the same code path.
        ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        TcpHost host = new TcpHost();

        Thread serverThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Socket accepted = server.accept();
                    accepted.setSoTimeout(10000);
                    int first = accepted.getInputStream().read();
                    accepted.getOutputStream().write(first + 1);
                    accepted.getOutputStream().flush();
                    accepted.close();
                }
                catch (IOException ignored) {
                }
            }
        }, "tcp-host-test-echo");
        serverThread.setDaemon(true);
        serverThread.start();

        try {
            String connectionId = connectionIdFrom(host.tcpConnect("127.0.0.1", server.getLocalPort()));

            assertEquals("writing to an open connection must succeed",
                null, host.tcpWrite(connectionId, HostFunctions.base64Encode(new byte[] { 41 })));

            String dataEvent = host.awaitInboundEvent(5000);
            assertNotNull("the reply must reach the engine", dataEvent);
            assertTrue("the reply must arrive as a data event, said: " + dataEvent,
                dataEvent.contains("\"kind\":\"data\""));
        }
        finally {
            host.shutdown();
            server.close();
        }
    }

    //
    // An outgoing connection with a request on it counts as live work.
    //
    // The engine's run loop asks this to decide whether to block on the inbound queue or fall
    // through to a one millisecond sleep and go round again. A task that only makes requests binds
    // no listener, so before this it looked idle for as long as a reply was outstanding: measured on
    // a Pixel 6 mid sync, the loop went round about seventeen hundred times in five seconds and
    // spent nearly two of those five in those sleeps.
    //
    @Test
    public void anOpenConnectionCountsAsLiveWorkAndAClosedOneDoesNot() throws Exception {
        ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        TcpHost host = new TcpHost();

        Thread serverThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Socket accepted = server.accept();
                    accepted.setSoTimeout(10000);
                    accepted.getInputStream().read();
                    accepted.close();
                }
                catch (IOException ignored) {
                }
            }
        }, "tcp-host-test-live");
        serverThread.setDaemon(true);
        serverThread.start();

        try {
            assertTrue("a host with no connection at all must not claim live work",
                !host.hasLiveConnections());

            String connectionId = connectionIdFrom(host.tcpConnect("127.0.0.1", server.getLocalPort()));
            assertTrue("an open outgoing connection must count as live work", host.hasLiveConnections());

            host.tcpClose(connectionId);
            assertTrue("a closed connection must stop counting as live work, or the loop would park for ever",
                !host.hasLiveConnections());
        }
        finally {
            host.shutdown();
            server.close();
        }
    }
}
