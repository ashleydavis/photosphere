package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.assertEquals;

import org.junit.After;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

//
// Plain-JVM tests that every public host.* delegation on HostBridge actually routes to its backing
// layer (TcpHost/UdpHost/TlsHost/CryptoHost/HostFunctions/media runners). The backing layers have
// their own deep tests; these assert the bridge's one-line pass-throughs invoke them and return their
// result. The sha256 and notImplemented delegations are excluded here because they route through
// HostFunctions.notImplemented, which calls android.util.Log (not available on the plain JVM); those
// are covered by the iOS bridge tests.
//
public final class HostBridgeDelegationTest {

    //
    // A fresh temporary storage root per test.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // Callbacks that ignore every event; the delegation tests never assert on them.
    //
    private static final class NoopCallbacks implements EngineCallbacks {

        @Override
        public void onTaskSucceeded(PooledTask task, String outputsJson) {
        }

        @Override
        public void onTaskFailed(PooledTask task, String errorMessage) {
        }

        @Override
        public void onTaskMessage(PooledTask task, String messageJson) {
        }

        @Override
        public void queueChildTask(String parentTaskId, String childTaskId, String type, String dataJson, String source) {
        }
    }

    //
    // The bridge under test, rebuilt per test and shut down (releasing sockets) in tearDown.
    //
    private HostBridge bridge;

    //
    // Builds a bridge sandboxed to the temp root.
    //
    private HostBridge newBridge() {
        bridge = new HostBridge(new NoopCallbacks(), new CancellationState(), "session-1", temporaryFolder.getRoot());
        return bridge;
    }

    @After
    public void tearDown() {
        if (bridge != null) {
            bridge.tcp.shutdown();
            bridge.udp.shutdown();
            bridge.tls.shutdown();
        }
    }

    //
    // Extracts a string field's value from a flat JSON envelope.
    //
    private static String stringField(String json, String field) {
        String marker = "\"" + field + "\":\"";
        int start = json.indexOf(marker) + marker.length();
        int end = json.indexOf("\"", start);
        return json.substring(start, end);
    }

    @Test
    public void tcpDelegationsRouteToTcpHost() {
        HostBridge bridge = newBridge();
        String listen = bridge.tcpListen("127.0.0.1", 0);
        assertTrue(listen.contains("\"listenerId\""));
        String listenerId = stringField(listen, "listenerId");

        // Unknown ids are no-ops that return null through the delegation.
        assertNull(bridge.tcpWrite("C999", Base64.getEncoder().encodeToString("x".getBytes(StandardCharsets.UTF_8))));
        assertNull(bridge.tcpClose("C999"));
        assertNull(bridge.tcpStopListening(listenerId));
    }

    @Test
    public void udpDelegationsRouteToUdpHost() {
        HostBridge bridge = newBridge();
        String bind = bridge.udpBind("127.0.0.1", 0, false);
        assertTrue(bind.contains("\"socketId\""));
        String socketId = stringField(bind, "socketId");

        // Send never throws across the bridge; it returns null on success or an error envelope.
        String send = bridge.udpSend(socketId, Base64.getEncoder().encodeToString("x".getBytes(StandardCharsets.UTF_8)), "127.0.0.1", 9);
        assertTrue(send == null || send.startsWith("@@HOSTERR@@"));
        assertNull(bridge.udpClose(socketId));
    }

    @Test
    public void tlsDelegationsRouteToTlsHost() {
        HostBridge bridge = newBridge();

        // Unknown ids are no-ops returning null.
        assertNull(bridge.tlsWrite("C999", ""));
        assertNull(bridge.tlsClose("C999"));
        assertNull(bridge.tlsStopListening("L999"));

        // Listen with an invalid cert/key exercises the delegation and returns an error envelope.
        String listen = bridge.tlsListen("127.0.0.1", 0, "not-a-cert", "not-a-key");
        assertTrue(listen.startsWith("@@HOSTERR@@"));

        // Connecting to a refused port exercises the delegation and returns an error envelope.
        String connect = bridge.tlsConnect("127.0.0.1", 1, false);
        assertTrue(connect.startsWith("@@HOSTERR@@"));
    }

    @Test
    public void cryptoDelegationsRouteToCryptoHost() {
        HostBridge bridge = newBridge();
        String keyPair = bridge.cryptoGenerateRsaKeyPair(2048);
        assertTrue(keyPair.contains("privateKeyPem"));
        assertTrue(keyPair.contains("publicKeyPem"));

        // An invalid key exercises the sign delegation and returns an error envelope (never throws).
        String signed = bridge.cryptoSignSha256("not-a-key", Base64.getEncoder().encodeToString("data".getBytes(StandardCharsets.UTF_8)));
        assertTrue(signed.startsWith("@@HOSTERR@@"));
    }

    @Test
    public void fsDelegationsRouteToHostFunctions() {
        HostBridge bridge = newBridge();
        String helloBase64 = Base64.getEncoder().encodeToString("hello".getBytes(StandardCharsets.UTF_8));

        bridge.fsMkdir("dir", true);
        bridge.fsWriteFile("dir/a.txt", helloBase64, false);
        assertTrue(bridge.fsAccess("dir/a.txt"));
        assertEquals(helloBase64, bridge.fsReadFile("dir/a.txt"));
        assertTrue(bridge.fsStat("dir/a.txt").contains("\"isFile\":true"));
        assertTrue(bridge.fsReaddir("dir").contains("a.txt"));

        bridge.fsRename("dir/a.txt", "dir/b.txt");
        assertFalse(bridge.fsAccess("dir/a.txt"));
        assertTrue(bridge.fsAccess("dir/b.txt"));

        bridge.fsUnlink("dir/b.txt");
        assertFalse(bridge.fsAccess("dir/b.txt"));

        bridge.fsWriteFile("dir/c.txt", helloBase64, false);
        bridge.fsRm("dir", true, false);
        assertFalse(bridge.fsAccess("dir"));
    }

    @Test
    public void mediaDelegationsRouteToRunners() {
        HostBridge bridge = newBridge();

        // The runners are not linked in the unit-test JVM, so each returns the { exitCode, output } JSON
        // wrapping a not-linked result. The point here is that the bridge routes to runMediaTool.
        assertTrue(bridge.imageMagick("[\"info:\"]").contains("\"exitCode\""));
        assertTrue(bridge.ffmpeg("[\"-version\"]").contains("\"exitCode\""));
        assertTrue(bridge.ffprobe("[\"-version\"]").contains("\"exitCode\""));
    }
}
