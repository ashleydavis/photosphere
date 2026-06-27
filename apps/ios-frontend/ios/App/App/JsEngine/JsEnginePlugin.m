#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

//
// Objective-C bridging declaration that registers the Swift JsEnginePlugin with Capacitor under the
// JS name "JsEngine" and exposes its methods to the bridge. Capacitor requires this macro file (it
// cannot discover @objc Swift methods on its own). addListener / removeListener are handled by the
// Capacitor base class and are not declared here. Each promise-returning method is declared as
// CAPPluginReturnPromise so the JS-side calls resolve/reject as expected.
//
CAP_PLUGIN(JsEnginePlugin, "JsEngine",
    CAP_PLUGIN_METHOD(addTask, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(cancelTasks, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(shutdown, CAPPluginReturnPromise);
)
