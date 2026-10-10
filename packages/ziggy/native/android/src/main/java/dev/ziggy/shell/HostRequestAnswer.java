package dev.ziggy.shell;

import java.nio.charset.StandardCharsets;

// How a host request's answer crosses to the core: UTF-8 bytes whose first byte says whether the request succeeded (1) or failed (0),
// followed by the JSON text of the answer or the text of the reason. The core's JNI code reads the first byte and passes the rest on.
public final class HostRequestAnswer {
    // The first byte of an answer to a request that succeeded.
    public static final byte SUCCEEDED = 1;

    // The first byte of an answer to a request that failed.
    public static final byte FAILED = 0;

    private HostRequestAnswer() {
    }

    // The answer to a request that succeeded, with the JSON text of what it gave.
    public static byte[] succeeded(String answerJson) {
        return encode(SUCCEEDED, answerJson);
    }

    // The answer to a request that failed, with the reason.
    public static byte[] failed(String reason) {
        return encode(FAILED, reason);
    }

    private static byte[] encode(byte status, String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        byte[] answer = new byte[bytes.length + 1];
        answer[0] = status;
        System.arraycopy(bytes, 0, answer, 1, bytes.length);
        return answer;
    }
}
