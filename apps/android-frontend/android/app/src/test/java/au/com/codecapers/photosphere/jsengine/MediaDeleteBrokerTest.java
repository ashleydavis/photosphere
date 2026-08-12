package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.net.Uri;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.util.ArrayList;
import java.util.List;

//
// Plain-JVM unit tests for where the thing that presents the system delete confirmation is
// registered, and for staging an answer in its place.
//
// The rule these are about: nothing is ever reported as deleted unless something actually said so.
// Answering "yes" when no confirmation was presented is how a photo the user still has gets treated
// as gone.
//
public final class MediaDeleteBrokerTest {

    //
    // A requester that records what it was asked and answers however the test says.
    //
    private static final class RecordingRequester implements MediaLibraryHost.DeleteRequester {
        final List<List<Uri>> requests = new ArrayList<>();
        boolean answer;

        RecordingRequester(boolean answer) {
            this.answer = answer;
        }

        @Override
        public boolean requestDelete(List<Uri> itemUris) {
            requests.add(new ArrayList<>(itemUris));
            return answer;
        }
    }

    @Before
    public void clearBroker() {
        MediaDeleteBroker.clear();
        MediaDeleteBroker.consumeStagedOutcome();
    }

    @After
    public void clearBrokerAfter() {
        MediaDeleteBroker.clear();
        MediaDeleteBroker.consumeStagedOutcome();
    }

    @Test
    public void withNothingRegisteredNothingIsReportedAsDeleted() {
        assertFalse(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
    }

    @Test
    public void aRegisteredRequesterIsAsked() {
        RecordingRequester requester = new RecordingRequester(true);
        MediaDeleteBroker.register(requester);

        assertTrue(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
        assertEquals(1, requester.requests.size());
    }

    @Test
    public void aRegisteredRequesterThatRefusesIsBelieved() {
        MediaDeleteBroker.register(new RecordingRequester(false));

        assertFalse(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
    }

    @Test
    public void clearingLeavesNothingAbleToDelete() {
        MediaDeleteBroker.register(new RecordingRequester(true));
        MediaDeleteBroker.clear();

        assertFalse(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
    }

    @Test
    public void aStagedOutcomeStandsInForTheDialog() {
        RecordingRequester requester = new RecordingRequester(false);
        MediaDeleteBroker.register(requester);
        MediaDeleteBroker.stageOutcome(true);

        assertTrue(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
        // The real requester was never asked, so no dialog was presented.
        assertEquals(0, requester.requests.size());
    }

    @Test
    public void aStagedRefusalIsAnsweredAsARefusal() {
        MediaDeleteBroker.register(new RecordingRequester(true));
        MediaDeleteBroker.stageOutcome(false);

        assertFalse(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
    }

    @Test
    public void aStagedOutcomeAnswersOneRequestOnly() {
        RecordingRequester requester = new RecordingRequester(false);
        MediaDeleteBroker.register(requester);
        MediaDeleteBroker.stageOutcome(true);

        assertTrue(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
        // The second request falls through to the real requester rather than being answered by a
        // staged outcome nobody staged again.
        assertFalse(MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>()));
        assertEquals(1, requester.requests.size());
    }

    @Test
    public void aStagedRequestRecordsHowManyItemsItWasAskedToDelete() {
        MediaDeleteBroker.stageOutcome(true);

        // A Uri cannot be built in a plain-JVM test: android.net.Uri is a stub here and its factory
        // methods return null. What matters is that the request is recorded and carries the same
        // number of items it was given, which nulls show just as well as real content uris.
        List<Uri> uris = new ArrayList<>();
        uris.add(null);
        uris.add(null);

        MediaDeleteBroker.requester().requestDelete(uris);

        List<List<Uri>> recorded = MediaDeleteBroker.stagedRequests();
        assertEquals(1, recorded.size());
        assertEquals(2, recorded.get(0).size());
    }

    @Test
    public void aStagedRequestIsACopy() {
        MediaDeleteBroker.stageOutcome(true);
        List<Uri> uris = new ArrayList<>();
        uris.add(null);

        MediaDeleteBroker.requester().requestDelete(uris);
        uris.clear();

        // Clearing the caller's list must not empty what was recorded, or a test would be asserting
        // against a list the code under test went on to change.
        assertEquals(1, MediaDeleteBroker.stagedRequests().get(0).size());
    }

    @Test
    public void stagingAgainStartsTheRecordAfresh() {
        MediaDeleteBroker.stageOutcome(true);
        MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>());

        MediaDeleteBroker.stageOutcome(true);

        assertEquals(0, MediaDeleteBroker.stagedRequests().size());
    }

    @Test
    public void nothingIsStagedToBeginWith() {
        assertFalse(MediaDeleteBroker.hasStagedOutcome());

        MediaDeleteBroker.stageOutcome(true);
        assertTrue(MediaDeleteBroker.hasStagedOutcome());

        MediaDeleteBroker.requester().requestDelete(new ArrayList<Uri>());
        assertFalse(MediaDeleteBroker.hasStagedOutcome());
    }

    @Test
    public void aFixedOutcomeRequesterAlwaysAnswersTheSameWay() {
        assertTrue(MediaDeleteBroker.fixedOutcome(true).requestDelete(new ArrayList<Uri>()));
        assertFalse(MediaDeleteBroker.fixedOutcome(false).requestDelete(new ArrayList<Uri>()));
    }
}
