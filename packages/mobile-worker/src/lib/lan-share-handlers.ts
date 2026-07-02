import { ITaskContext } from "task-queue";
import type {
    IReceiveShareTaskResult,
    IFindReceiverTaskResult,
    ISendPayloadTaskResult,
} from "api";

//
// Mobile stand-ins for the LAN-share task handlers.
//
// The real desktop/CLI handlers (packages/node-api/src/lib/lan-share.worker.ts) drive
// LanShareSender / LanShareReceiver, which import Node's dgram/https/tls. Those cannot be
// bundled for the embedded browser-target engine (the build hard-errors on Node builtins),
// and the native UDP/HTTPS/TLS host functions do not exist yet. Rather than fail the task
// (which would crash the share dialog and hide the pairing code), these handlers reproduce
// the "no peer on the network" outcome: they keep the task pending for the normal timeout
// window (so the sender keeps showing its pairing code), honour cancellation, then resolve
// with an empty result. When native networking lands, these are replaced by the real handlers.
//

//
// How long (in milliseconds) a receive/discovery task stays pending before giving up,
// matching the desktop SHARE_TIMEOUT_MS so the flow behaves the same on both platforms.
//
const SHARE_TIMEOUT_MS = 60000;

//
// How often (in milliseconds) to poll the task context for cancellation while waiting.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// Resolves after the timeout elapses or the task is cancelled, whichever comes first.
// Keeps the task pending (so the UI keeps showing its waiting/pairing-code state) without
// doing any networking.
//
function waitUntilTimeoutOrCancelled(context: ITaskContext, timeoutMs: number, pollIntervalMs: number): Promise<void> {
    return new Promise<void>(resolve => {
        let settled = false;

        const finish = () => {
            if (settled) {
                return;
            }
            settled = true;
            clearInterval(pollTimer);
            clearTimeout(timeoutTimer);
            resolve();
        };

        const pollTimer = setInterval(() => {
            if (context.isCancelled()) {
                finish();
            }
        }, pollIntervalMs);

        const timeoutTimer = setTimeout(finish, timeoutMs);
    });
}

//
// Mobile "receive-share" handler. Waits for the timeout or cancellation, then reports that
// no payload arrived (no sender can reach this device without native networking).
//
export async function receiveShareHandler(_data: any, context: ITaskContext): Promise<IReceiveShareTaskResult> {
    await waitUntilTimeoutOrCancelled(context, SHARE_TIMEOUT_MS, CANCEL_POLL_INTERVAL_MS);
    return { payload: null };
}

//
// Mobile "find-receiver" handler. Waits for the timeout or cancellation, then reports that
// no receiver was discovered on the LAN.
//
export async function findReceiverHandler(_data: any, context: ITaskContext): Promise<IFindReceiverTaskResult> {
    await waitUntilTimeoutOrCancelled(context, SHARE_TIMEOUT_MS, CANCEL_POLL_INTERVAL_MS);
    return { endpoint: null };
}

//
// Mobile "send-payload" handler. There is never a discovered endpoint to send to on mobile,
// so this reports failure immediately rather than pretending to transmit.
//
export async function sendPayloadHandler(_data: any): Promise<ISendPayloadTaskResult> {
    return { success: false };
}
