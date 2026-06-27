package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.List;

//
// A PoolListener that records every outcome the pool reports, so the dispatcher tests can assert
// completion order, which tasks succeeded/failed, and streamed messages.
//
public final class RecordingPoolListener implements EnginePool.PoolListener {

    //
    // The ids of tasks that succeeded, in the order the pool reported them.
    //
    public final List<String> succeededTaskIds = new ArrayList<>();

    //
    // The ids of tasks that failed, in the order the pool reported them.
    //
    public final List<String> failedTaskIds = new ArrayList<>();

    //
    // The ids of tasks that streamed a message, in order.
    //
    public final List<String> messageTaskIds = new ArrayList<>();

    //
    // Records a success.
    //
    @Override
    public void onTaskSucceeded(PooledTask task, String outputsJson) {
        succeededTaskIds.add(task.taskId);
    }

    //
    // Records a failure.
    //
    @Override
    public void onTaskFailed(PooledTask task, String errorMessage) {
        failedTaskIds.add(task.taskId);
    }

    //
    // Records a streamed message.
    //
    @Override
    public void onTaskMessage(PooledTask task, String messageJson) {
        messageTaskIds.add(task.taskId);
    }
}
