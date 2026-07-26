import { useEffect, useRef } from "react";
import { TaskQueue, TaskStatus, getQueueBackend } from "task-queue";
import type { ITaskResult } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type {
    IReceiveShareTaskResult,
    IFindReceiverTaskResult,
    ISendPayloadTaskResult,
    IShareReceiverEndpoint,
} from "api";

//
// Source tag used to group and cancel all LAN-share background tasks.
//
const LAN_SHARE_SOURCE = "lan-share";

//
// The set of LAN-share operations exposed by useLanShareTasks. Signatures match
// the corresponding methods on IPlatformContext exactly, keeping the opaque
// unknown payload/endpoint types so the platform interface needs no change.
//
export interface ILanShareTasks {
    // Starts hosting a receiver advertising the given pairing code. Does not wait.
    startShareReceive: (code: string) => Promise<void>;

    // Awaits the payload delivered to the receiver; resolves null on timeout/cancel.
    waitShareReceive: () => Promise<unknown>;

    // Cancels an in-flight receive and tears down the receiver.
    cancelShareReceive: () => Promise<void>;

    // Captures the payload/code and waits for a receiver to be discovered on the LAN.
    waitForReceiver: (payload: unknown, code: string) => Promise<unknown>;

    // Sends the previously captured payload to the discovered endpoint.
    sendToReceiver: (endpoint: unknown) => Promise<boolean>;

    // Cancels an in-flight send and tears down discovery.
    cancelShareSend: () => Promise<void>;
}

//
// Captured send state recorded by waitForReceiver and consumed by sendToReceiver.
//
interface ICapturedSend {
    // The payload to deliver once a receiver is found.
    payload: unknown;

    // The pairing code for this share session.
    code: string;
}

//
// Dispatches the LAN database-sharing flow through the shared TaskQueue instead
// of platform-specific IPC. On desktop the tasks run in the Electron utility
// worker (full Node); on mobile they dispatch to the embedded JS engine, where
// the native networking host functions back them.
//
export function useLanShareTasks(): ILanShareTasks {
    // Lazily-created queue that all share tasks are dispatched through.
    const queueRef = useRef<TaskQueue | null>(null);

    // Promise for the in-flight receive task, stored so waitShareReceive can await it later.
    const pendingReceiveRef = useRef<Promise<ITaskResult | undefined> | null>(null);

    // Payload/code captured by waitForReceiver, consumed by sendToReceiver.
    const capturedSendRef = useRef<ICapturedSend | null>(null);

    //
    // Returns the queue, creating it on first use.
    //
    function getQueue(): TaskQueue {
        if (!queueRef.current) {
            // The queue only needs the generator to mint task ids; a plain RandomUuidGenerator is
            // used (rather than useUuidGenerator) so the hook works wherever the platform provider is
            // mounted, including minimal trees like the stories route that have no UuidGeneratorProvider.
            queueRef.current = new TaskQueue(new RandomUuidGenerator(), LAN_SHARE_SOURCE);
        }
        return queueRef.current;
    }

    //
    // Shuts the queue down when the hosting component unmounts.
    //
    useEffect(() => {
        return () => {
            if (queueRef.current) {
                queueRef.current.shutdown();
                queueRef.current = null;
            }
        };
    }, []);

    //
    // Submits a receive-share task and stores the await promise without blocking.
    //
    async function startShareReceive(code: string): Promise<void> {
        const queue = getQueue();
        const taskId = queue.addTask("receive-share", { code });
        pendingReceiveRef.current = queue.awaitTask(taskId);
    }

    //
    // Awaits the receive task started by startShareReceive.
    // Returns the delivered payload, null on timeout/cancel, throws on task failure.
    //
    async function waitShareReceive(): Promise<unknown> {
        const pending = pendingReceiveRef.current;
        if (!pending) {
            return null;
        }
        const result = await pending;
        pendingReceiveRef.current = null;
        if (!result) {
            return null;
        }
        if (result.status === TaskStatus.Failed) {
            throw new Error(result.errorMessage || "Receive share failed");
        }
        if (result.status === TaskStatus.Succeeded) {
            const outputs = result.outputs as IReceiveShareTaskResult;
            return outputs.payload;
        }
        return null;
    }

    //
    // Captures the payload/code, submits a find-receiver task, and awaits discovery.
    // Returns the discovered endpoint, null on timeout/cancel, throws on task failure.
    //
    async function waitForReceiver(payload: unknown, code: string): Promise<unknown> {
        capturedSendRef.current = { payload, code };
        const queue = getQueue();
        const taskId = queue.addTask("find-receiver", { code });
        const result = await queue.awaitTask(taskId);
        if (!result) {
            return null;
        }
        if (result.status === TaskStatus.Failed) {
            throw new Error(result.errorMessage || "Find receiver failed");
        }
        if (result.status === TaskStatus.Succeeded) {
            const outputs = result.outputs as IFindReceiverTaskResult;
            return outputs.endpoint;
        }
        return null;
    }

    //
    // Sends the previously captured payload to the discovered endpoint.
    // Returns true if the receiver accepted the payload; false if nothing was captured.
    // Throws on task failure.
    //
    async function sendToReceiver(endpoint: unknown): Promise<boolean> {
        const captured = capturedSendRef.current;
        if (!captured) {
            return false;
        }
        const queue = getQueue();
        const taskId = queue.addTask("send-payload", {
            payload: captured.payload,
            code: captured.code,
            endpoint: endpoint as IShareReceiverEndpoint,
        });
        const result = await queue.awaitTask(taskId);
        if (!result) {
            return false;
        }
        if (result.status === TaskStatus.Failed) {
            throw new Error(result.errorMessage || "Send payload failed");
        }
        if (result.status === TaskStatus.Succeeded) {
            const outputs = result.outputs as ISendPayloadTaskResult;
            return outputs.success;
        }
        return false;
    }

    //
    // Cancels an in-flight receive, clearing the pending-receive promise.
    //
    async function cancelShareReceive(): Promise<void> {
        pendingReceiveRef.current = null;
        getQueueBackend().cancelTasks(LAN_SHARE_SOURCE);
    }

    //
    // Cancels an in-flight send, clearing the captured send state.
    //
    async function cancelShareSend(): Promise<void> {
        capturedSendRef.current = null;
        getQueueBackend().cancelTasks(LAN_SHARE_SOURCE);
    }

    return {
        startShareReceive,
        waitShareReceive,
        cancelShareReceive,
        waitForReceiver,
        sendToReceiver,
        cancelShareSend,
    };
}
