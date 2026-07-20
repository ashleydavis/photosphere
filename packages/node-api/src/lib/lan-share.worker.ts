import { ITaskContext } from "task-queue";
import { LanShareReceiver, LanShareSender } from "lan-share-network";
import type {
    IReceiveShareTaskData,
    IReceiveShareTaskResult,
    IFindReceiverTaskData,
    IFindReceiverTaskResult,
    ISendPayloadTaskData,
    ISendPayloadTaskResult,
    IDatabaseSharePayload,
    ISecretSharePayload,
} from "api";

//
// How long a receiver or sender waits (in milliseconds) before giving up.
//
const SHARE_TIMEOUT_MS = 60000;

//
// How often (in milliseconds) to poll the task context for cancellation.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// Polls the task context for cancellation and invokes onCancel the first time
// the task is reported cancelled. Returns a stop function that clears the poll timer.
//
function watchForCancellation(context: ITaskContext, onCancel: () => void): () => void {
    let cancelled = false;
    const timer = setInterval(() => {
        if (!cancelled && context.isCancelled()) {
            cancelled = true;
            onCancel();
        }
    }, CANCEL_POLL_INTERVAL_MS);

    return () => {
        clearInterval(timer);
    };
}

//
// "receive-share" background-task handler. Hosts a LAN receiver advertising the
// supplied pairing code and waits for a sender to deliver a payload.
// Returns the delivered payload, or null on timeout or cancellation.
//
export async function receiveShareHandler(data: IReceiveShareTaskData, context: ITaskContext): Promise<IReceiveShareTaskResult> {
    const receiver = new LanShareReceiver(SHARE_TIMEOUT_MS);
    await receiver.start(data.code);

    const stopWatching = watchForCancellation(context, () => receiver.cancel());
    try {
        const payload = await receiver.receive();
        return { payload: payload as IDatabaseSharePayload | ISecretSharePayload | null };
    }
    finally {
        stopWatching();
    }
}

//
// "find-receiver" background-task handler. Listens for a receiver's UDP broadcast
// for the given share session and returns the discovered endpoint, or null on
// timeout or cancellation.
//
export async function findReceiverHandler(data: IFindReceiverTaskData, context: ITaskContext): Promise<IFindReceiverTaskResult> {
    const sender = new LanShareSender(undefined, data.code);

    const stopWatching = watchForCancellation(context, () => sender.cancel());
    try {
        const endpoint = await sender.waitForReceiver(SHARE_TIMEOUT_MS);
        return { endpoint };
    }
    finally {
        stopWatching();
    }
}

//
// "send-payload" background-task handler. Delivers the given payload to a
// previously discovered receiver over HTTPS and reports whether it was accepted.
//
export async function sendPayloadHandler(data: ISendPayloadTaskData): Promise<ISendPayloadTaskResult> {
    const sender = new LanShareSender(data.payload, data.code);
    const success = await sender.send(data.endpoint);
    return { success };
}
