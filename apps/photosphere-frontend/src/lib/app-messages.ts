import type { IJsonValue, IMessageCallback, IZiggyBridge } from "ziggy";

//
// What each of Photosphere's own events holds as its data: the name of the event, and what it carries. The page routes an event by
// its type.
//
export interface IAppMessage {
    // The name of the event, such as "database-opened".
    type: string;

    // What the message or event carries, null when it carries nothing.
    data: IJsonValue;
}

//
// Photosphere's own messages and events over the bridge the native app injects. Ziggy gives the page one message handler in the
// core and one event listener in the page. A message is sent with its name and its data, which the core's message handler routes
// by the name. Photosphere names each event itself: an event's data is { type, data }, which this hands to the callbacks registered
// for that type. Ziggy's own messages and events (tasks, the test hooks) are not sent through this: they have their own calls on
// the bridge. Ziggy's menu event {type: "menu", item} arrives among the app's events but carries no data, so the platform provider
// listens for it on the bridge itself.
//
export class AppMessages {
    // The bridge the native app injects.
    private readonly ziggy: IZiggyBridge;

    // The callbacks registered for each event type.
    private readonly listeners: Map<string, IMessageCallback<any>[]> = new Map();

    // Whether this has registered its listener with the bridge, which it does once, for its first callback.
    private listening: boolean = false;

    constructor(ziggy: IZiggyBridge) {
        this.ziggy = ziggy;
    }

    //
    // Sends a message of the name and resolves with its message response, or rejects with the error it ended with.
    //
    invoke<TResponse>(name: string, data: IJsonValue): Promise<TResponse> {
        return this.ziggy.invoke<TResponse>(name, data);
    }

    //
    // Sends a message of the name that gets no message response.
    //
    send(name: string, data: IJsonValue): void {
        this.ziggy.send(name, data);
    }

    //
    // Registers a callback for the events of the type, which it is given the data of.
    //
    onEvent<TData>(type: string, callback: IMessageCallback<TData>): void {
        const callbacks = this.listeners.get(type) ?? [];
        callbacks.push(callback);
        this.listeners.set(type, callbacks);
        if (!this.listening) {
            this.listening = true;
            this.ziggy.onEvent<IAppMessage>(event => this.receive(event));
        }
    }

    //
    // Removes every callback registered for the events of the type.
    //
    removeAllListeners(type: string): void {
        this.listeners.delete(type);
    }

    //
    // Hands an event to the callbacks registered for its type.
    //
    private receive(event: IAppMessage): void {
        const callbacks = this.listeners.get(event.type);
        if (!callbacks) {
            return;
        }
        for (const callback of callbacks.slice()) {
            callback(event.data);
        }
    }
}
