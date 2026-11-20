import { lanShareErrorMessage, noReceiverMessage, noSenderMessage } from "../../lib/lan-share-error-message";

describe("lanShareErrorMessage", () => {

    test("uses the caught error's message", () => {
        expect(lanShareErrorMessage(new Error("Send payload failed"))).toBe("Send payload failed");
    });

    test("falls back to a generic message when the error has no message", () => {
        expect(lanShareErrorMessage(new Error(""))).toBe("LAN share failed. Please try again.");
    });
});

describe("noSenderMessage", () => {

    test("says only that nobody connected when no device was heard", () => {
        expect(noSenderMessage(false)).toBe("No sender connected within 60 seconds.");
    });

    test("says a device was found with a different pairing code when one was heard", () => {
        expect(noSenderMessage(true)).toBe("No sender connected within 60 seconds. A device was found, but it is using a different pairing code.");
    });
});

describe("noReceiverMessage", () => {

    test("says only that no receiver was found when no device was heard", () => {
        expect(noReceiverMessage(false)).toBe("No receiver found within 60 seconds.");
    });

    test("says a device was found with a different pairing code when one was heard", () => {
        expect(noReceiverMessage(true)).toBe("No receiver found within 60 seconds. A device was found, but it is using a different pairing code.");
    });
});
