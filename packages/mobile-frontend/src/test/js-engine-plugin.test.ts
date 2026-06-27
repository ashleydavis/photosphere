import { registerPlugin } from "@capacitor/core";
import { JsEngine } from "../lib/js-engine-plugin";

//
// The plugin interface is registered against the native "JsEngine" plugin. These tests use
// the mocked @capacitor/core (see jest.config.js) to assert the wiring without a device.
//
describe("JsEngine plugin interface", () => {
    test("registers the plugin under the name JsEngine", () => {
        expect(registerPlugin).toHaveBeenCalledWith("JsEngine");
    });

    test("the registered plugin stand-in carries the plugin name", () => {
        expect((JsEngine as any).__pluginName).toBe("JsEngine");
    });
});
