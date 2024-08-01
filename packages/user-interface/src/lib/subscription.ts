//
// Represents a subscription for updates.
//
export interface ISubscription {
    //
    // Unsubscribes from updates.
    //
    unsubscribe(): void;
}

export type CallbackFn<DataT> = (payload: DataT) => void;

//
// Represents a subscription to new gallery items.
//
export class Subscription<DataT> implements ISubscription {
    constructor(public callback: CallbackFn<DataT>,
        private _unsubscribe: (subscription: ISubscription) => void) {
    }

    //
    // Subscribes the subcription.
    //
    unsubscribe() {
        this._unsubscribe(this);
    }

    //
    // Invokes the subcription callback.
    //
    invoke(payload: DataT): void {
        this.callback(payload);
    }
}

//
// Defines an observable stream of data that can be subscribed to.
//
export interface IObservable<DataT> {
    //
    // Subscribes to update to the stream of data.
    //
    subscribe(callback: CallbackFn<DataT>): ISubscription

    //
    // Invokes the callbacks for subscriptions.
    //
    invoke(payload: DataT): void;
}

//
// Defines an observable stream of data that can be subscribed to.
//
export class Observable<DataT> implements IObservable<DataT> {

    //
    // Active subscriptions to receive updates.
    //
    private subscriptions: Subscription<DataT>[] = [];

    //
    // Pending payloads waiting to deliver on first subscription.
    //
    private pendingPayloads: DataT[] = [];

    //
    // Subscribes to update to the stream of data.
    //
    subscribe(callback: CallbackFn<DataT>): ISubscription {
        const subscription = new Subscription<DataT>(callback, subscription => {
            const index = this.subscriptions.indexOf(subscription as Subscription<DataT>);
            if (index !== -1) {
                this.subscriptions.splice(index, 1);
            }    
        });
        this.subscriptions.push(subscription);

        for (const payload of this.pendingPayloads) {
            subscription.invoke(payload);
        }
        this.pendingPayloads = [];
        return subscription;
    }

    //
    // Invokes the callbacks for subscriptions.
    //
    invoke(payload: DataT): void {
        if (this.subscriptions.length === 0) {
            this.pendingPayloads.push(payload);
        }
        else {
            for (const subscription of this.subscriptions) {
                subscription.invoke(payload);
            }            
        }
    }
}


