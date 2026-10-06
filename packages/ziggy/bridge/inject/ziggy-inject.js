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

    // Dropped files. A web view does not give the page the real paths of the files dropped on it: WebKitGTK lists file addresses as a
    // type of the drop and gives no way to read them, and no File objects, and the others give Files that have no path readable by the
    // page. The shell reads the paths natively and records them with the core. This catches every drop of files before the page does,
    // asks the core for the paths of the last drop, and fires the drop again holding one File per path, which it makes itself and
    // remembers the path of. getPathForFile then answers from that memory, as Electron's does, so a page written for Electron runs
    // unchanged. The Files are empty: a page that wants a dropped file's contents reads the path. WebView2 hands the shell the Files
    // themselves, so there the shell reads their paths first. A drop of something else, such as a link, is left alone.
    var redispatchedDrops = new WeakSet();
    var pathsOfDroppedFiles = new WeakMap();

    function getPathForFile(file) {
        return pathsOfDroppedFiles.get(file);
    }

    function isDropOfFiles(transfer) {
        var types = Array.prototype.slice.call(transfer.types);
        if (transfer.files.length > 0 || types.indexOf("Files") >= 0) {
            return true;
        }
        // A file's address is listed but cannot be read. A link's address can be, and is not a file.
        return types.indexOf("text/uri-list") >= 0 && transfer.getData("text/uri-list").indexOf("http") !== 0;
    }

    function onDrop(event) {
        if (redispatchedDrops.has(event) || !event.dataTransfer || !isDropOfFiles(event.dataTransfer)) {
            return;
        }
        var files = Array.prototype.slice.call(event.dataTransfer.files);
        event.preventDefault();
        event.stopImmediatePropagation();
        var target = event.target;
        if (files.length > 0 && window.chrome && window.chrome.webview && window.chrome.webview.postMessageWithAdditionalObjects) {
            try {
                window.chrome.webview.postMessageWithAdditionalObjects("ziggy-file", files);
            }
            catch (error) {
                // WebView2 takes only Files that came from a drop. The core is still asked, and answers with the last drop it was told of.
                console.warn("Ziggy: WebView2 would not hand the shell these files, so their paths are not known from the files themselves.", error);
            }
        }
        invoke("get-dropped-paths", null).then(function (paths) {
            var transfer = new window.DataTransfer();
            paths.forEach(function (path) {
                var file = new window.File([], path.split(/[\\/]/).pop());
                pathsOfDroppedFiles.set(file, path);
                transfer.items.add(file);
            });
            var again = new window.DragEvent("drop", {
                bubbles: true,
                cancelable: true,
                composed: true,
                clientX: event.clientX,
                clientY: event.clientY,
                dataTransfer: transfer,
            });
            redispatchedDrops.add(again);
            target.dispatchEvent(again);
        });
    }

    window.addEventListener("drop", onDrop, true);


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
            getPathForFile: getPathForFile,
        }),
    });
    Object.defineProperty(window, "__ziggyReceive", { value: receive });
})();
