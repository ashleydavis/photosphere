import { stateKeyPath } from "../lib/state-key-path";

describe("stateKeyPath", () => {
    test("maps each declared key to its own path", () => {
        expect(stateKeyPath("lastFolder")).toBe("desktop.last_folder");
        expect(stateKeyPath("lastDownloadFolder")).toBe("desktop.last_download_folder");
        expect(stateKeyPath("devToolsOpen")).toBe("desktop.dev_tools_open");
        expect(stateKeyPath("recentSearches")).toBe("searches.recent");
        expect(stateKeyPath("gallerySort")).toBe("gallery.sort");
        expect(stateKeyPath("galleryRowHeight")).toBe("gallery.row_height");
    });

    test("encodes a dot in an interface key so it stays one key", () => {
        expect(stateKeyPath("sidebar.collapsed")).toBe("ui.sidebar%2Ecollapsed");
    });

    test("keeps a key and a key that starts with it at different paths", () => {
        expect(stateKeyPath("a")).toBe("ui.a");
        expect(stateKeyPath("a.b")).toBe("ui.a%2Eb");
        expect(stateKeyPath("a")).not.toBe(stateKeyPath("a.b"));
    });

    test("encodes a percent before a dot, so a key holding the encoding's own text does not collide", () => {
        expect(stateKeyPath("a%2Eb")).toBe("ui.a%252Eb");
        expect(stateKeyPath("a%2Eb")).not.toBe(stateKeyPath("a.b"));
    });

    test("leaves a key with no dot or percent as it is under ui", () => {
        expect(stateKeyPath("sidebar")).toBe("ui.sidebar");
    });
});
