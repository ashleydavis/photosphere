package au.com.codecapers.photosphere.jsengine;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

//
// The native TLS layer behind the five host.tls* functions. LAN-share's receiver runs an HTTPS server
// with a runtime self-signed cert, and its sender connects with certificate pinning; the embedded
// engine cannot perform a TLS handshake, so this class provides both a TLS server (built from the PEM
// cert/key the TypeScript generates) and a cert-capturing TLS client. It mirrors TcpHost but over TLS:
// inbound connection/data/close events are queued for the engine worker thread and delivered into the
// JS tls shim via globalThis.__tlsEvent; writes and closes are driven synchronously.
//
// One TlsHost belongs to one engine context. JS-facing calls run on the engine worker thread; the
// accept/read callbacks run on their own threads and only touch the concurrent collections and the
// event queue. Base64 uses the portable HostFunctions codec so this class is unit-testable on a plain
// JVM (no android.* dependency).
//
public final class TlsHost {

    //
    // The in-memory keystore password (the keystore never leaves the process, so the value is arbitrary).
    //
    private static final char[] KEYSTORE_PASSWORD = "photosphere".toCharArray();

    //
    // Inbound events (connection / data / close) as JSON strings, drained by the engine worker thread.
    //
    private final LinkedBlockingQueue<String> inboundEvents = new LinkedBlockingQueue<>();

    //
    // Open listeners keyed by listener id.
    //
    private final ConcurrentHashMap<String, SSLServerSocket> listeners = new ConcurrentHashMap<>();

    //
    // Open connections (accepted or client) keyed by connection id.
    //
    private final ConcurrentHashMap<String, SSLSocket> connections = new ConcurrentHashMap<>();

    //
    // Monotonic source of listener / connection ids.
    //
    private final AtomicInteger nextId = new AtomicInteger(1);

    //
    // Set true on shutdown so the accept/read loops exit.
    //
    private volatile boolean shuttingDown = false;

    //
    // host.tlsListen(host, port, certPem, keyPem): builds an SSL context from the PEM cert/key, binds a
    // TLS listener, and starts accepting on a background thread. Returns a JSON string
    // { listenerId, port }, or an error envelope on failure.
    //
    public String tlsListen(String host, int port, String certPem, String keyPem) {
        try {
            SSLContext sslContext = buildServerContext(certPem, keyPem);
            SSLServerSocket server = (SSLServerSocket) sslContext.getServerSocketFactory().createServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(host, port));

            final String listenerId = "TL" + nextId.getAndIncrement();
            listeners.put(listenerId, server);

            Thread acceptThread = new Thread(() -> acceptLoop(listenerId, server), "tls-accept-" + listenerId);
            acceptThread.setDaemon(true);
            acceptThread.start();

            int boundPort = server.getLocalPort();
            return "{\"listenerId\":\"" + listenerId + "\",\"port\":" + boundPort + "}";
        }
        catch (Exception error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Builds a server SSLContext presenting the given PEM certificate and PKCS#8 private key.
    //
    private SSLContext buildServerContext(String certPem, String keyPem) throws Exception {
        byte[] pkcs8 = CryptoHost.derFromPem(keyPem);
        PrivateKey privateKey = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(pkcs8));

        CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
        Certificate certificate = certificateFactory.generateCertificate(new ByteArrayInputStream(certPem.getBytes("UTF-8")));

        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        keyStore.load(null, KEYSTORE_PASSWORD);
        keyStore.setKeyEntry("key", privateKey, KEYSTORE_PASSWORD, new Certificate[] { certificate });

        KeyManagerFactory keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keyManagerFactory.init(keyStore, KEYSTORE_PASSWORD);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(keyManagerFactory.getKeyManagers(), null, null);
        return sslContext;
    }

    //
    // Accepts TLS connections until the listener is closed. Each accepted connection is registered, a
    // "connection" event is enqueued (before the read thread starts), then a read thread streams inbound
    // bytes.
    //
    private void acceptLoop(String listenerId, SSLServerSocket server) {
        while (!shuttingDown && !server.isClosed()) {
            SSLSocket socket;
            try {
                socket = (SSLSocket) server.accept();
            }
            catch (IOException error) {
                break;
            }

            final String connectionId = "TC" + nextId.getAndIncrement();
            connections.put(connectionId, socket);
            enqueue("{\"kind\":\"connection\",\"listenerId\":\"" + listenerId + "\",\"connectionId\":\"" + connectionId + "\"}");

            Thread readThread = new Thread(() -> readLoop(connectionId, socket), "tls-read-" + connectionId);
            readThread.setDaemon(true);
            readThread.start();
        }
    }

    //
    // host.tlsConnect(host, port): opens a TLS client connection trusting any certificate, completes the
    // handshake, and returns a JSON string { connectionId, peerCertBase64 } (the server's cert DER,
    // base64) so the JS side can pin it. A read thread streams inbound bytes. Returns an error envelope
    // on failure.
    //
    public String tlsConnect(String host, int port) {
        try {
            SSLContext sslContext = buildTrustAllClientContext();
            SSLSocket socket = (SSLSocket) sslContext.getSocketFactory().createSocket(host, port);
            socket.startHandshake();

            Certificate[] peerCertificates = socket.getSession().getPeerCertificates();
            byte[] peerCertDer = ((X509Certificate) peerCertificates[0]).getEncoded();
            String peerCertBase64 = HostFunctions.base64Encode(peerCertDer);

            final String connectionId = "TC" + nextId.getAndIncrement();
            connections.put(connectionId, socket);

            Thread readThread = new Thread(() -> readLoop(connectionId, socket), "tls-read-" + connectionId);
            readThread.setDaemon(true);
            readThread.start();

            return "{\"connectionId\":\"" + connectionId + "\",\"peerCertBase64\":\"" + peerCertBase64 + "\"}";
        }
        catch (Exception error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Builds a client SSLContext that trusts any server certificate. LAN-share pins the certificate
    // itself (by comparing the SHA-256 fingerprint to the one in the UDP broadcast), so transport-level
    // validation is intentionally disabled here.
    //
    private SSLContext buildTrustAllClientContext() throws Exception {
        TrustManager[] trustAll = new TrustManager[] {
            new X509TrustManager() {
                @Override
                public void checkClientTrusted(X509Certificate[] chain, String authType) {
                }

                @Override
                public void checkServerTrusted(X509Certificate[] chain, String authType) {
                }

                @Override
                public X509Certificate[] getAcceptedIssuers() {
                    return new X509Certificate[0];
                }
            }
        };
        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(null, trustAll, null);
        return sslContext;
    }

    //
    // Reads inbound bytes from one connection, enqueuing a base64 "data" event per chunk, then a "close"
    // event when the remote closes or the read fails.
    //
    private void readLoop(String connectionId, SSLSocket socket) {
        byte[] buffer = new byte[16 * 1024];
        try {
            InputStream input = socket.getInputStream();
            int bytesRead = input.read(buffer);
            while (bytesRead != -1) {
                byte[] chunk = new byte[bytesRead];
                System.arraycopy(buffer, 0, chunk, 0, bytesRead);
                enqueue("{\"kind\":\"data\",\"connectionId\":\"" + connectionId + "\",\"base64\":\"" + HostFunctions.base64Encode(chunk) + "\"}");
                bytesRead = input.read(buffer);
            }
        }
        catch (IOException ignored) {
            // Remote closed or reset; fall through to the close event.
        }
        finally {
            // Drop the closed connection so hasLiveConnections stops counting it (the engine uses that
            // to keep a client-request task alive only while its connection is actually open).
            connections.remove(connectionId);
            enqueue("{\"kind\":\"close\",\"connectionId\":\"" + connectionId + "\"}");
        }
    }

    //
    // host.tlsWrite(connectionId, base64): writes base64-decoded bytes to a TLS connection. Returns null
    // on success or an error envelope on failure.
    //
    public String tlsWrite(String connectionId, String base64) {
        SSLSocket socket = connections.get(connectionId);
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
    // host.tlsClose(connectionId): closes one TLS connection.
    //
    public String tlsClose(String connectionId) {
        SSLSocket socket = connections.remove(connectionId);
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
    // host.tlsStopListening(listenerId): closes a TLS listener so it accepts no further connections.
    //
    public String tlsStopListening(String listenerId) {
        SSLServerSocket server = listeners.remove(listenerId);
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
    // Returns true while any listener is still open (so the engine keeps a receiver task alive).
    //
    public boolean hasLiveListeners() {
        return !listeners.isEmpty();
    }

    //
    // Returns true while any TLS connection is still open. The engine uses this to keep a client-request
    // task (the sender's cert-pinned HTTPS transfer) alive while it awaits the server's response, since
    // such a task binds no listener of its own.
    //
    public boolean hasLiveConnections() {
        return !connections.isEmpty();
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
        for (SSLServerSocket server : listeners.values()) {
            try {
                server.close();
            }
            catch (IOException ignored) {
            }
        }
        listeners.clear();
        for (SSLSocket socket : connections.values()) {
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
