package dev.ziggy.example;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.webkit.WebView;
import dev.ziggy.shell.ZiggyShell;

// The Ziggy example's one screen: a web view run by Ziggy's shell. What is the example's own is the name of its core library
// and the mobile limits on the core's threads.
public final class MainActivity extends Activity {
    private ZiggyShell shell;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WebView webView = new WebView(this);
        setContentView(webView);
        shell = new ZiggyShell(this, webView, "ziggy_example", 5, 2);
        shell.start();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (!shell.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data);
        }
    }

    @Override
    protected void onDestroy() {
        shell.destroy();
        super.onDestroy();
    }
}
