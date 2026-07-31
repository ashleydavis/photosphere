package au.com.codecapers.photosphere.jsengine;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Arrays;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

//
// The native TCP socket layer behind the four host.tcp* functions. The embedded engine cannot open
// or accept TCP connections in JavaScript, so this class binds a loopback ServerSocket, accepts
// connections, and reads bytes on background threads. Inbound events (a new connection, received
// bytes, a closed connection) are pushed onto a thread-safe queue that the engine drains on its own
// worker thread and delivers into the JS net shim via globalThis.__tcpEvent. Outbound writes and
// closes are driven synchronously from the running handler.
//
// One TcpHost belongs to one engine context (the one running the long-lived asset-server task). All
// JS-facing calls (tcpListen/tcpWrite/tcpClose/tcpStopListening) run on the engine's worker thread;
// the accept/read callbacks run on their own threads and only touch the concurrent collections and
// the event queue, never the JS context.
//
public final class TcpHost {

    //
    // Log tag for socket diagnostics.
    //
    private static final String LOG_TAG = "JsEngineTcp";

    //
    // How long an outbound connect may take before it is abandoned, in milliseconds.
    //
    private static final int CONNECT_TIMEOUT_MS = 10000;

    //
    // Inbound events (connection / data / close) as JSON strings, drained by the engine worker thread.
    //
    private final LinkedBlockingQueue<String> inboundEvents = new LinkedBlockingQueue<>();

    //
    // Open listeners keyed by listener id.
    //
    private final ConcurrentHashMap<String, ServerSocket> listeners = new ConcurrentHashMap<>();

    //
    // Accepted connections keyed by connection id.
    //
    private final ConcurrentHashMap<String, Socket> connections = new ConcurrentHashMap<>();

    //
    // Monotonic source of listener / connection ids.
    //
    private final AtomicInteger nextId = new AtomicInteger(1);

    //
    // Set true on shutdown so the accept loops exit.
    //
    private volatile boolean shuttingDown = false;

    //
    // host.tcpListen(host, port): binds a loopback TCP listener (port 0 = OS-assigned) and starts
    // accepting connections on a background thread. Returns a JSON string { listenerId, port } with
    // the actual bound port, or an error envelope on failure.
    //
    public String tcpListen(String host, int port) {
        try {
            ServerSocket server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress("127.0.0.1", port));
            final String listenerId = "L" + nextId.getAndIncrement();
            listeners.put(listenerId, server);

            Thread acceptThread = new Thread(() -> acceptLoop(listenerId, server), "tcp-accept-" + listenerId);
            acceptThread.setDaemon(true);
            acceptThread.start();

            int boundPort = server.getLocalPort();
            return "{\"listenerId\":\"" + listenerId + "\",\"port\":" + boundPort + "}";
        }
        catch (IOException error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Accepts connections until the listener is closed. Each accepted connection is registered, a
    // "connection" event is enqueued (before the read thread starts, so the JS server registers the
    // socket before any data arrives), then a read thread streams its inbound bytes.
    //
    private void acceptLoop(String listenerId, ServerSocket server) {
        while (!shuttingDown && !server.isClosed()) {
            Socket socket;
            try {
                socket = server.accept();
            }
            catch (IOException error) {
                break;
            }

            final String connectionId = "C" + nextId.getAndIncrement();
            connections.put(connectionId, socket);
            enqueue("{\"kind\":\"connection\",\"listenerId\":\"" + listenerId + "\",\"connectionId\":\"" + connectionId + "\"}");

            Thread readThread = new Thread(() -> readLoop(connectionId, socket), "tcp-read-" + connectionId);
            readThread.setDaemon(true);
            readThread.start();
        }
    }

    //
    // Reads inbound bytes from one connection, enqueuing a base64 "data" event per chunk, then a
    // "close" event when the remote closes or the read fails.
    //
    private void readLoop(String connectionId, Socket socket) {
        byte[] buffer = new byte[16 * 1024];
        try {
            InputStream input = socket.getInputStream();
            int bytesRead = input.read(buffer);
            while (bytesRead != -1) {
                String base64 = HostFunctions.base64Encode(Arrays.copyOf(buffer, bytesRead));
                enqueue("{\"kind\":\"data\",\"connectionId\":\"" + connectionId + "\",\"base64\":\"" + base64 + "\"}");
                bytesRead = input.read(buffer);
            }
        }
        catch (IOException ignored) {
            // Remote closed or reset; fall through to the close event.
        }
        finally {
            enqueue("{\"kind\":\"close\",\"connectionId\":\"" + connectionId + "\"}");
        }
    }

    //
    // host.tcpConnect(host, port): opens an outbound TCP connection, registers it, and starts reading
    // its inbound bytes on a background thread. Returns a JSON string { connectionId }, or an error
    // envelope on failure.
    //
    // This is the outbound half of the socket layer, and it is what lets an `http://` endpoint be
    // reached as plain HTTP with no TLS in the path. Unlike the listener it targets a remote address,
    // so it is not restricted to loopback.
    //
    public String tcpConnect(String host, int port) {
        try {
            Socket socket = new Socket();
            socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);
            final String connectionId = "C" + nextId.getAndIncrement();
            connections.put(connectionId, socket);

            Thread readThread = new Thread(() -> readLoop(connectionId, socket), "tcp-read-" + connectionId);
            readThread.setDaemon(true);
            readThread.start();

            return "{\"connectionId\":\"" + connectionId + "\"}";
        }
        catch (IOException error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // host.tcpWrite(connectionId, base64): writes base64-decoded bytes to an accepted connection.
    // Returns null on success or an error envelope on failure.
    //
    public String tcpWrite(String connectionId, String base64) {
        Socket socket = connections.get(connectionId);
        if (socket == null) {
            return null;
        }
        try {
            OutputStream output = socket.getOutputStream();
            output.write(HostFunctions.base64Decode(base64));
            output.flush();
            return null;
        }
        catch (IOException error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // host.tcpClose(connectionId): closes one accepted connection.
    //
    public String tcpClose(String connectionId) {
        Socket socket = connections.remove(connectionId);
        if (socket != null) {
            try {
                socket.close();
            }
            catch (IOException ignored) {
            }
        }
        return null;
    }

    //
    // host.tcpStopListening(listenerId): closes a listener so it accepts no further connections.
    //
    public String tcpStopListening(String listenerId) {
        ServerSocket server = listeners.remove(listenerId);
        if (server != null) {
            try {
                server.close();
            }
            catch (IOException ignored) {
            }
        }
        return null;
    }

    //
    // Returns the next inbound event JSON without blocking, or null when none is queued.
    //
    public String pollInboundEvent() {
        return inboundEvents.poll();
    }

    //
    // Blocks up to timeoutMs for the next inbound event JSON, returning it (or null on timeout). Used
    // by the engine loop to park the worker thread while a server is idle instead of busy-spinning.
    //
    public String awaitInboundEvent(long timeoutMs) {
        try {
            return inboundEvents.poll(timeoutMs, TimeUnit.MILLISECONDS);
        }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return null;
        }
    }

    //
    // Returns true while any listener is still open (i.e. a server task is running).
    //
    public boolean hasLiveListeners() {
        return !listeners.isEmpty();
    }

    //
    // Enqueues an inbound event JSON for the engine worker thread to deliver.
    //
    private void enqueue(String eventJson) {
        inboundEvents.offer(eventJson);
    }

    //
    // Closes all listeners and connections and clears the queue. Called when the engine is disposed.
    //
    public void shutdown() {
        shuttingDown = true;
        for (ServerSocket server : listeners.values()) {
            try {
                server.close();
            }
            catch (IOException ignored) {
            }
        }
        listeners.clear();
        for (Socket socket : connections.values()) {
            try {
                socket.close();
            }
            catch (IOException ignored) {
            }
        }
        connections.clear();
        inboundEvents.clear();
    }
}
