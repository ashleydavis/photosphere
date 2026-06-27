package au.com.codecapers.photosphere;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

import au.com.codecapers.photosphere.jsengine.JsEnginePlugin;

//
// The app's main activity. Registers the JsEngine Capacitor plugin (which runs background
// tasks in an embedded QuickJS engine) before Capacitor initialises the bridge, so the
// plugin is available to the WebView from the first load.
//
public class MainActivity extends BridgeActivity {

    //
    // Registers the JsEngine plugin and then continues normal Capacitor bridge startup.
    //
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(JsEnginePlugin.class);
        super.onCreate(savedInstanceState);
    }
}
