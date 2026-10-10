package dev.ziggy.shell;

import static org.junit.Assert.assertEquals;

import java.nio.charset.StandardCharsets;
import org.junit.Test;

// Plain-JVM tests for how an answer to a host request crosses to the core: a status byte, then the answer or the reason as UTF-8.
public final class HostRequestAnswerTest {
    @Test
    public void aSuccessIsMarkedAndCarriesTheAnswer() {
        byte[] answer = HostRequestAnswer.succeeded("{\"granted\":true}");
        assertEquals(HostRequestAnswer.SUCCEEDED, answer[0]);
        assertEquals("{\"granted\":true}", new String(answer, 1, answer.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void aFailureIsMarkedAndCarriesTheReason() {
        byte[] answer = HostRequestAnswer.failed("Photo access was refused.");
        assertEquals(HostRequestAnswer.FAILED, answer[0]);
        assertEquals("Photo access was refused.", new String(answer, 1, answer.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void textOutsideTheBasicPlaneSurvives() {
        String text = "\"photo-📷\"";
        byte[] answer = HostRequestAnswer.succeeded(text);
        assertEquals(text, new String(answer, 1, answer.length - 1, StandardCharsets.UTF_8));
    }

    @Test
    public void anEmptyAnswerIsJustTheStatusByte() {
        assertEquals(1, HostRequestAnswer.succeeded("").length);
    }
}
