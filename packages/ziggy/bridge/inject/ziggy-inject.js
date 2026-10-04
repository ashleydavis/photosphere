// The script every shell injects into the page before its own scripts run. It exposes window.ziggy and nothing else
// that a page should use, and it finds the web view's own native handle so the page never has to:
// WebKitGTK and WKWebView post through window.webkit.messageHandlers.ziggy, WebView2 through window.chrome.webview,
// and the Android WebView through the interface object named ZiggyAndroid.
//
// A page message is the JSON text { "id", "channel", "data" } for a request, and the same without an id for a one-way
// message. The shell delivers a message from the core by calling window.__ziggyReceive with the message as an object:
// { "id", "ok", "data" } or { "id", "ok": false, "error" } for a reply, and { "channel", "data" } for an event.
(function () {
    if (window.ziggy) {
        return;
    }

    var nativePost = findNativePost();
    var nextId = 1;
    var pending = new Map();
    var listeners = new Map();

    function findNativePost() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ziggy) {
            return function (text) {
                window.webkit.messageHandlers.ziggy.postMessage(text);
            };
        }
        if (window.chrome && window.chrome.webview) {
            return function (text) {
                window.chrome.webview.postMessage(text);
            };
        }
        if (window.ZiggyAndroid) {
            return function (text) {
                window.ZiggyAndroid.postMessage(text);
            };
        }
        throw new Error("Ziggy: this web view has no native message handler to post to.");
    }

    function invoke(channel, data) {
        return new Promise(function (resolve, reject) {
            var id = nextId++;
            pending.set(id, { resolve: resolve, reject: reject });
            try {
                nativePost(JSON.stringify({ id: id, channel: channel, data: data }));
            }
            catch (error) {
                pending.delete(id);
                reject(error);
            }
        });
    }

    function send(channel, data) {
        nativePost(JSON.stringify({ channel: channel, data: data }));
    }

    function onMessage(channel, callback) {
        var callbacks = listeners.get(channel);
        if (!callbacks) {
            callbacks = [];
            listeners.set(channel, callbacks);
        }
        callbacks.push(callback);
    }

    function removeAllListeners(channel) {
        listeners.delete(channel);
    }

    function receive(message) {
        if (message.id !== undefined && message.ok !== undefined) {
            var request = pending.get(message.id);
            if (!request) {
                console.error("Ziggy: a reply arrived for a request nobody is waiting for", message);
                return;
            }
            pending.delete(message.id);
            if (message.ok) {
                request.resolve(message.data);
            }
            else {
                request.reject(new Error(message.error));
            }
            return;
        }
        var callbacks = listeners.get(message.channel);
        if (!callbacks) {
            if (message.channel === "core-error") {
                console.error("Ziggy core error:", message.data && message.data.error);
            }
            return;
        }
        callbacks.slice().forEach(function (callback) {
            callback(message.data);
        });
    }

    Object.defineProperty(window, "ziggy", {
        value: Object.freeze({
            invoke: invoke,
            send: send,
            onMessage: onMessage,
            removeAllListeners: removeAllListeners,
        }),
    });
    Object.defineProperty(window, "__ziggyReceive", { value: receive });
})();
