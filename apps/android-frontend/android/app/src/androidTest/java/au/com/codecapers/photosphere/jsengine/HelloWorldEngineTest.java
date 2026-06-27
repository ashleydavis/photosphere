package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;

import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

//
// On-device end-to-end test for the QuickJS engine. It runs the real worker.bundle.js (loaded
// from the app assets) inside a QuickJsTaskEngine on the emulator/device and asserts that the
// "hello-world" background task completes with the expected greeting and streams its progress
// message. This is the deterministic proof that the embedded engine actually executes a task,
// independent of the WebView/UI. Needs the native QuickJS libs, so it is an instrumented test.
//
// Run with: ./gradlew :app:connectedDebugAndroidTest
//
@RunWith(JUnit4.class)
public final class HelloWorldEngineTest {

    //
    // Runs the hello-world task through the engine and asserts the streamed message and result.
    //
    @Test
    public void helloWorldTaskRunsInTheEngine() throws InterruptedException {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        File storageRoot = context.getFilesDir();
        CancellationState cancellationState = new CancellationState();

        PooledTask task = new PooledTask("test-task-1", "hello-world", "{\"name\":\"World\"}", "test-source");
        cancellationState.register(task.taskId, false);

        QuickJsTaskEngine engine = new QuickJsTaskEngine(context, cancellationState, "test-session", storageRoot);

        List<String> messages = new ArrayList<>();
        String[] outputsJson = new String[1];
        String[] failure = new String[1];
        CountDownLatch latch = new CountDownLatch(1);

        engine.runTask(task, new EngineCallbacks() {
            @Override
            public void onTaskSucceeded(PooledTask completed, String json) {
                outputsJson[0] = json;
                latch.countDown();
            }

            @Override
            public void onTaskFailed(PooledTask completed, String errorMessage) {
                failure[0] = errorMessage;
                latch.countDown();
            }

            @Override
            public void onTaskMessage(PooledTask running, String messageJson) {
                synchronized (messages) {
                    messages.add(messageJson);
                }
            }
        });

        boolean settled = latch.await(15, TimeUnit.SECONDS);
        engine.dispose();

        assertTrue("Task did not settle within 15s", settled);
        assertTrue("Task failed: " + failure[0], failure[0] == null);
        assertNotNull("No outputs returned", outputsJson[0]);
        assertTrue("Result missing greeting, was: " + outputsJson[0], outputsJson[0].contains("Hello, World!"));
        assertTrue("Result missing platform, was: " + outputsJson[0], outputsJson[0].contains("android"));

        synchronized (messages) {
            assertTrue("No progress message streamed", messages.size() >= 1);
            assertTrue("Progress message wrong, was: " + messages, messages.get(0).contains("saying hello"));
        }
    }
}
