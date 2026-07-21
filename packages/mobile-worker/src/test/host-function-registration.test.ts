import * as fs from "fs";
import * as path from "path";
import { EXPECTED_HOST_FUNCTIONS } from "../lib/host-functions";

//
// Guards the seam between the worker's expected host functions and the two native engines that
// install them.
//
// A host function only reaches the embedded worker if native explicitly registers it: Android calls
// host.setProperty("name", ...) in QuickJsTaskEngine, iOS calls host.setValue(..., forProperty:
// "name") in HostBridge.swift. Neither reflects over the bridge class, so adding a public method to
// HostBridge and stopping there leaves the function silently unbound: buildHost substitutes the
// NOT IMPLEMENTED stub and the failure only appears when a task calls it on a device.
//
// That is exactly how secureStoreGet shipped unbound on Android. These tests turn that into a unit
// test failure instead of a wasted device run.
//

//
// The repository root, four levels up from this test file.
//
const REPO_ROOT = path.resolve(__dirname, "../../../..");

//
// The Android engine source that registers each host function into the QuickJS global.
//
const ANDROID_ENGINE_PATH = path.join(
    REPO_ROOT,
    "apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/QuickJsTaskEngine.java");

//
// The iOS bridge source that installs each host function into the JavaScriptCore context.
//
const IOS_BRIDGE_PATH = path.join(REPO_ROOT, "apps/ios-frontend/ios/App/App/JsEngine/HostBridge.swift");

//
// Extracts the host function names Android registers via host.setProperty("name", ...).
//
function readAndroidRegisteredNames(): Set<string> {
    const source = fs.readFileSync(ANDROID_ENGINE_PATH, "utf8");
    const matches = source.matchAll(/host\.setProperty\(\s*"([A-Za-z0-9_]+)"/g);
    return new Set(Array.from(matches, match => match[1]));
}

//
// Extracts the host function names iOS installs via host.setValue(..., forProperty: "name").
//
function readIosRegisteredNames(): Set<string> {
    const source = fs.readFileSync(IOS_BRIDGE_PATH, "utf8");
    const matches = source.matchAll(/forProperty:\s*"([A-Za-z0-9_]+)"/g);
    return new Set(Array.from(matches, match => match[1]));
}

describe("native host function registration", () => {
    test("every expected host function is registered by the Android engine", () => {
        const registered = readAndroidRegisteredNames();

        const missing = EXPECTED_HOST_FUNCTIONS.filter(name => !registered.has(name));

        expect(missing).toEqual([]);
    });

    test("every expected host function is installed by the iOS bridge", () => {
        const registered = readIosRegisteredNames();

        const missing = EXPECTED_HOST_FUNCTIONS.filter(name => !registered.has(name));

        expect(missing).toEqual([]);
    });

    test("the expected list is non-empty, so a broken parse cannot pass these tests vacuously", () => {
        expect(EXPECTED_HOST_FUNCTIONS.length).toBeGreaterThan(0);
        expect(readAndroidRegisteredNames().size).toBeGreaterThan(0);
        expect(readIosRegisteredNames().size).toBeGreaterThan(0);
    });
});
