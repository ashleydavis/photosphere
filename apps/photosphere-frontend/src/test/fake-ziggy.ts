import type { IJsonValue, IMessageCallback, IZiggyBridge } from "ziggy-ui";

//
// A message the page sent with send or invoke.
//
export interface IRecordedMessage {
    // The channel it was sent on.
    channel: string;

    // The data it carried.
    data: IJsonValue;
}

//
// A stand-in for the bridge a shell injects, which records what the page sends and lets a test play the core's events. An
// invoke is answered with the reply a test set for the channel, and an invoke on a channel with no reply set rejects, as the
// core does for a channel it does not know.
//
export class FakeZiggy implements IZiggyBridge {
    // Every send, in order.
    sent: IRecordedMessage[] = [];

    // Every invoke, in order.
    invoked: IRecordedMessage[] = [];

    // The reply to give for each channel an invoke is made on.
    replies: Map<string, IJsonValue> = new Map();

    // The channels removeAllListeners was called for, in order.
    removed: string[] = [];

    // The callbacks registered for each channel.
    private listeners: Map<string, IMessageCallback<any>[]> = new Map();

    invoke<TReply>(channel: string, data: IJsonValue): Promise<TReply> {
        this.invoked.push({ channel, data });
        if (!this.replies.has(channel)) {
            return Promise.reject(new Error(`No reply set for ${channel}`));
        }
        return Promise.resolve(this.replies.get(channel) as TReply);
    }

    send(channel: string, data: IJsonValue): void {
        this.sent.push({ channel, data });
    }

    onMessage<TData>(channel: string, callback: IMessageCallback<TData>): void {
        const existing = this.listeners.get(channel) ?? [];
        existing.push(callback);
        this.listeners.set(channel, existing);
    }

    removeAllListeners(channel: string): void {
        this.removed.push(channel);
        this.listeners.delete(channel);
    }

    getPathForFile(_file: File): string | undefined {
        return undefined;
    }

    // Plays an event from the core to the callbacks registered for the channel.
    emit(channel: string, data: IJsonValue): void {
        for (const callback of this.listeners.get(channel) ?? []) {
            callback(data);
        }
    }

    // How many callbacks are registered for the channel.
    listenerCount(channel: string): number {
        return (this.listeners.get(channel) ?? []).length;
    }
}
