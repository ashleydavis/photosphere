package au.com.codecapers.photosphere.jsengine;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.util.Arrays;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

//
// The native UDP datagram layer behind the three host.udp* functions. The embedded engine cannot open
// UDP sockets, which LAN-share discovery needs (the receiver broadcasts availability and the sender
// listens for it). This class binds a DatagramSocket, receives datagrams on a background thread, and
// pushes inbound "message" events onto a thread-safe queue the engine drains on its worker thread and
// delivers into the JS dgram shim via globalThis.__udpEvent. Outbound sends are driven synchronously.
//
// One UdpHost belongs to one engine context. All JS-facing calls (udpBind/udpSend/udpClose) run on the
// engine's worker thread; the receive callbacks run on their own threads and only touch the concurrent
// collections and the event queue, never the JS context. Base64 uses the portable HostFunctions codec
// so this class is unit-testable on a plain JVM (no android.* dependency).
//
public final class UdpHost {

    //
    // Inbound "message" events as JSON strings, drained by the engine worker thread.
    //
    private final LinkedBlockingQueue<String> inboundEvents = new LinkedBlockingQueue<>();

    //
    // Open sockets keyed by socket id.
    //
    private final ConcurrentHashMap<String, DatagramSocket> sockets = new ConcurrentHashMap<>();

    //
    // Monotonic source of socket ids.
    //
    private final AtomicInteger nextId = new AtomicInteger(1);

    //
    // Set true on shutdown so the receive loops exit.
    //
    private volatile boolean shuttingDown = false;

    //
    // host.udpBind(host, port, broadcast): binds a UDP socket (broadcast enabled when requested, address
    // reuse always on) and starts receiving on a background thread. Returns a JSON string
    // { socketId, port } with the actual bound port, or an error envelope on failure.
    //
    public String udpBind(String host, int port, boolean broadcast) {
        try {
            DatagramSocket socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            if (broadcast) {
                socket.setBroadcast(true);
            }
            socket.bind(new InetSocketAddress(host, port));

            final String socketId = "U" + nextId.getAndIncrement();
            sockets.put(socketId, socket);

            Thread receiveThread = new Thread(() -> receiveLoop(socketId, socket), "udp-recv-" + socketId);
            receiveThread.setDaemon(true);
            receiveThread.start();

            int boundPort = socket.getLocalPort();
            return "{\"socketId\":\"" + socketId + "\",\"port\":" + boundPort + "}";
        }
        catch (Exception error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Receives datagrams until the socket is closed, enqueuing a "message" event (sender address/port and
    // base64 payload) per datagram.
    //
    private void receiveLoop(String socketId, DatagramSocket socket) {
        byte[] buffer = new byte[64 * 1024];
        while (!shuttingDown && !socket.isClosed()) {
            DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
            try {
                socket.receive(packet);
            }
            catch (IOException error) {
                break;
            }
            byte[] data = Arrays.copyOf(packet.getData(), packet.getLength());
            String base64 = HostFunctions.base64Encode(data);
            String address = packet.getAddress() != null ? packet.getAddress().getHostAddress() : "";
            enqueue("{\"kind\":\"message\",\"socketId\":\"" + socketId
                + "\",\"address\":\"" + HostFunctions.jsonEscape(address) + "\",\"port\":" + packet.getPort()
                + ",\"base64\":\"" + base64 + "\"}");
        }
    }

    //
    // host.udpSend(socketId, base64, host, port): sends base64-decoded bytes as a datagram to host/port.
    // Returns null on success or an error envelope on failure.
    //
    public String udpSend(String socketId, String base64, String host, int port) {
        DatagramSocket socket = sockets.get(socketId);
        if (socket == null) {
            return null;
        }
        try {
            byte[] data = HostFunctions.base64Decode(base64);
            InetAddress address = InetAddress.getByName(host);
            socket.send(new DatagramPacket(data, data.length, address, port));
            return null;
        }
        catch (IOException error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // host.udpClose(socketId): closes a UDP socket.
    //
    public String udpClose(String socketId) {
        DatagramSocket socket = sockets.remove(socketId);
        if (socket != null) {
            socket.close();
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
    // Blocks up to timeoutMs for the next inbound event JSON, returning it (or null on timeout).
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
    // Returns true while any UDP socket is still open (so the engine keeps the task alive).
    //
    public boolean hasLiveSockets() {
        return !sockets.isEmpty();
    }

    //
    // Enqueues an inbound event JSON for the engine worker thread to deliver.
    //
    private void enqueue(String eventJson) {
        inboundEvents.offer(eventJson);
    }

    //
    // Closes all sockets and clears the queue. Called when the engine is disposed.
    //
    public void shutdown() {
        shuttingDown = true;
        for (DatagramSocket socket : sockets.values()) {
            socket.close();
        }
        sockets.clear();
        inboundEvents.clear();
    }
}
