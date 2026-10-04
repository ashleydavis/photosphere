//
// The page's view of Ziggy: the four methods every shell exposes as window.ziggy, and the JSON types messages are made of.
//

//
// A JSON object.
//
export interface IJsonObject {
    [key: string]: IJsonValue;
}

//
// Any JSON value.
//
export type IJsonValue = string | number | boolean | null | IJsonValue[] | IJsonObject;

//
// Called with the data of an event the core sends on a channel.
//
export type IMessageCallback<TData> = (data: TData) => void;

//
// What every shell injects into the page as window.ziggy. Nothing wider than these four methods is exposed, and the
// web view's own native handle is never used by the page directly.
//
export interface IZiggyBridge {
    //
    // Sends a request on a channel and resolves with the core's reply, or rejects with the core's error.
    //
    invoke<TReply>(channel: string, data: IJsonValue): Promise<TReply>;

    //
    // Sends a one-way message on a channel. There is no reply.
    //
    send(channel: string, data: IJsonValue): void;

    //
    // Registers a callback for the events the core sends on a channel.
    //
    onMessage<TData>(channel: string, callback: IMessageCallback<TData>): void;

    //
    // Removes every callback registered for a channel.
    //
    removeAllListeners(channel: string): void;
}

declare global {
    interface Window {
        // Injected by the shell before the page's scripts run.
        ziggy: IZiggyBridge;
    }
}
