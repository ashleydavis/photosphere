package au.com.codecapers.photosphere.ziggy;

import android.app.Activity;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;

// Asks the user for runtime permissions on behalf of a core worker thread, which waits for the answer. The activity forwards
// onRequestPermissionsResult here, and calls cancelPending when it is being destroyed so a waiting worker is let go.
public final class PermissionRequester {
    // The request code of the one permission prompt that can be on screen at a time.
    private static final int REQUEST_CODE = 0x5B00;

    private final Activity activity;

    // Held for the whole of a request, so only one prompt is on screen at a time.
    private final Object requestMutex = new Object();

    // Where the waiting thread receives the result, or null when no prompt is on screen.
    private volatile BlockingQueue<Boolean> pending;

    public PermissionRequester(Activity activity) {
        this.activity = activity;
    }

    // Shows the system prompt for the permissions and waits until the user has answered it. Returns false when the prompt was
    // abandoned because the activity is being destroyed. How much was granted is read afterwards from the permissions themselves,
    // because a prompt can grant some of what was asked and not the rest.
    public boolean request(final String[] permissions) throws InterruptedException {
        synchronized (requestMutex) {
            BlockingQueue<Boolean> answer = new ArrayBlockingQueue<Boolean>(1);
            pending = answer;
            try {
                activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        activity.requestPermissions(permissions, REQUEST_CODE);
                    }
                });
                return answer.take();
            } finally {
                pending = null;
            }
        }
    }

    // Feeds the user's answer to the thread waiting for it. The activity calls this from onRequestPermissionsResult. Returns whether
    // the result was one of this class's prompts.
    public boolean onRequestPermissionsResult(int requestCode) {
        BlockingQueue<Boolean> waiting = pending;
        if (waiting == null || requestCode != REQUEST_CODE) {
            return false;
        }
        waiting.offer(Boolean.TRUE);
        return true;
    }

    // Lets go of a thread waiting for a prompt that will never be answered, because the activity is going away.
    public void cancelPending() {
        BlockingQueue<Boolean> waiting = pending;
        if (waiting != null) {
            waiting.offer(Boolean.FALSE);
        }
    }
}
