import { lanShareErrorMessage } from "../../lib/lan-share-error-message";

describe("lanShareErrorMessage", () => {

    test("uses the caught error's message", () => {
        expect(lanShareErrorMessage(new Error("Send payload failed"))).toBe("Send payload failed");
    });

    test("falls back to a generic message when the error has no message", () => {
        expect(lanShareErrorMessage(new Error(""))).toBe("LAN share failed. Please try again.");
    });
});
