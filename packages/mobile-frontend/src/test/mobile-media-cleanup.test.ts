import { JsEngine } from "../lib/js-engine-plugin";
import { setInjectedDeleteOutcome } from "../lib/mobile-media-cleanup";

//
// The registered plugin is a plain stand-in object under test (see capacitor-core.mock.ts), so the
// method the staging goes through is installed on it here.
//
const plugin = JsEngine as any;

describe("staging the photo library delete outcome", () => {

    beforeEach(() => {
        plugin.stageMediaDeleteOutcome = jest.fn(async () => undefined);
    });

    test("a staged confirmation reaches the native layer as \"deleted\"", async () => {
        await setInjectedDeleteOutcome("deleted");

        expect(plugin.stageMediaDeleteOutcome).toHaveBeenCalledWith({ outcome: "deleted" });
    });

    test("a staged refusal reaches the native layer as \"cancelled\"", async () => {
        await setInjectedDeleteOutcome("cancelled");

        // The two answers must not be interchangeable. A refusal read as a confirmation would have
        // the app believe photos are gone from the device when they are still there, and go on to
        // free space that is still in use.
        expect(plugin.stageMediaDeleteOutcome).toHaveBeenCalledWith({ outcome: "cancelled" });
    });

    test("staging waits for the native layer rather than returning before it has taken effect", async () => {
        let staged = false;
        plugin.stageMediaDeleteOutcome = jest.fn(async () => {
            await Promise.resolve();
            staged = true;
        });

        await setInjectedDeleteOutcome("deleted");

        // A test stages the answer and then triggers the delete. Returning early would race: the
        // delete request would go out before the answer was in place, and the real system dialog
        // would appear in a test that cannot tap it.
        expect(staged).toBe(true);
    });
});
