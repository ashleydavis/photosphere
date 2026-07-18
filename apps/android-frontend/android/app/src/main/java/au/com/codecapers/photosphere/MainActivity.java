package au.com.codecapers.photosphere;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebView;

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
        injectTestConfig();
    }

    //
    // In test mode (launched with the photosphereTestMode intent extra) injects the host
    // control bridge address into the WebView as globalThis.__PHOTOSPHERE_TEST__, which the
    // frontend reads to open its test-driver WebSocket. Soft emulators can take tens of
    // seconds before the page context exists, so injection is retried on a long schedule;
    // the frontend also polls for the global for a matching window.
    //
    private void injectTestConfig() {
        Intent intent = getIntent();
        if (intent == null || !intent.getBooleanExtra("photosphereTestMode", false)) {
            return;
        }
        String hostExtra = intent.getStringExtra("photosphereTestHost");
        final String host = hostExtra != null ? hostExtra : "localhost";
        final int port = intent.getIntExtra("photosphereTestPort", 0);
        final String script = "globalThis.__PHOTOSPHERE_TEST__ = { host: '" + host + "', port: " + port + " };";
        final WebView webView = getBridge().getWebView();
        final Handler handler = new Handler(Looper.getMainLooper());
        final int[] delays = {
            200, 600, 1200, 2500, 5000, 10000, 20000, 30000, 45000, 60000, 90000
        };
        for (final int delay : delays) {
            handler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    webView.evaluateJavascript(script, null);
                }
            }, delay);
        }
    }
}
