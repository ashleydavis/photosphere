#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

//
// Objective-C bridging declaration that registers the Swift SecureStorePlugin with Capacitor under the
// JS name "SecureStore" and exposes its methods to the bridge. Capacitor requires this macro file (it
// cannot discover @objc Swift methods on its own). Each promise-returning method is declared as
// CAPPluginReturnPromise so the JS-side calls resolve/reject as expected.
//
CAP_PLUGIN(SecureStorePlugin, "SecureStore",
    CAP_PLUGIN_METHOD(get, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(set, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(delete, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(keys, CAPPluginReturnPromise);
)
