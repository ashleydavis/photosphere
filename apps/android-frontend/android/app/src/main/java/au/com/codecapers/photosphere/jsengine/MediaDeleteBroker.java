package au.com.codecapers.photosphere.jsengine;

import android.net.Uri;

import java.util.ArrayList;
import java.util.List;

//
// Where the thing that can present the system delete confirmation is registered.
//
// Deleting media the app does not own needs a system dialog, which needs an Activity. The engines
// that ask for a deletion run on background threads in a pool and have no Activity, and they are
// created and destroyed as tasks come and go, so the requester cannot be handed to each one at
// construction. It is registered once by the plugin and read by whichever engine needs it.
//
// A test stages an outcome here instead of registering the real requester, which is what lets the
// batching, the selection and the handling of both answers be tested without a system dialog that
// no test can tap. Nothing is staged in production, so the real request is issued.
//
public final class MediaDeleteBroker {

    //
    // The registered requester, or null when nothing can present the confirmation.
    //
    private static volatile MediaLibraryHost.DeleteRequester registered;

    //
    // Not instantiable; only static state and helpers.
    //
    private MediaDeleteBroker() {
    }

    //
    // Registers what can present the system delete confirmation. Called by the plugin once it has an
    // Activity, and by a test staging an outcome.
    //
    public static void register(MediaLibraryHost.DeleteRequester requester) {
        registered = requester;
    }

    //
    // Forgets the registered requester, so nothing can delete until one is registered again.
    //
    public static void clear() {
        registered = null;
    }

    //
    // The registered requester, or null. A null is not turned into a requester that answers "yes":
    // reporting a photo as deleted when nothing asked anyone is how a source file the user still has
    // gets treated as gone.
    //
    public static MediaLibraryHost.DeleteRequester requester() {
        return new MediaLibraryHost.DeleteRequester() {
            @Override
            public boolean requestDelete(List<Uri> itemUris) {
                // A staged answer stands in for the system dialog, and is used by one request only.
                Boolean staged = consumeStagedOutcome();
                if (staged != null) {
                    recordStagedRequest(itemUris);
                    return staged;
                }

                MediaLibraryHost.DeleteRequester real = registered;
                if (real == null) {
                    // Nothing can present the confirmation, so nothing was deleted. Answering "yes"
                    // here would report a photo as gone while it is still on the device.
                    return false;
                }
                return real.requestDelete(itemUris);
            }
        };
    }

    //
    // A requester that answers the same way every time, for staging an outcome in a test.
    //
    public static MediaLibraryHost.DeleteRequester fixedOutcome(final boolean deleted) {
        return new MediaLibraryHost.DeleteRequester() {
            @Override
            public boolean requestDelete(List<Uri> itemUris) {
                return deleted;
            }
        };
    }

    //
    // The answer staged for the next delete request, or null when none is staged.
    //
    private static volatile Boolean stagedOutcome;

    //
    // The requests a staged outcome answered, so a test can see what was actually asked for.
    //
    private static final List<List<Uri>> stagedRequests = new ArrayList<>();

    //
    // Stages the answer to the next delete request, instead of presenting the system dialog.
    //
    // This is what lets everything above the dialog be tested: choosing which photos are confirmed,
    // batching them into one request, and handling both answers. The dialog itself cannot be tapped
    // by an automated test, and its wording and controls change between Android versions.
    //
    // The staged answer is consumed by one request, so a test that stages "deleted" once does not
    // silently answer every later request as well.
    //
    public static void stageOutcome(boolean deleted) {
        synchronized (stagedRequests) {
            stagedRequests.clear();
        }
        stagedOutcome = deleted;
    }

    //
    // Reads and clears the staged answer, or returns null when none is staged.
    //
    static Boolean consumeStagedOutcome() {
        Boolean outcome = stagedOutcome;
        stagedOutcome = null;
        return outcome;
    }

    //
    // Records what a staged request was asked to delete.
    //
    static void recordStagedRequest(List<Uri> itemUris) {
        synchronized (stagedRequests) {
            stagedRequests.add(new ArrayList<>(itemUris));
        }
    }

    //
    // The requests a staged outcome answered, most recent last.
    //
    public static List<List<Uri>> stagedRequests() {
        synchronized (stagedRequests) {
            return new ArrayList<>(stagedRequests);
        }
    }

    //
    // Whether an answer is staged for the next request.
    //
    public static boolean hasStagedOutcome() {
        return stagedOutcome != null;
    }
}
