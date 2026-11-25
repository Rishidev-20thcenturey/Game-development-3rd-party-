package com.rishidev.turbokartrally;

import android.app.Activity;
import android.content.Intent;
import android.content.res.AssetManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * Turbo Kart Rally — a full-screen WebView that runs the bundled Three.js game offline.
 *
 * Game files live in assets/www and are served from a virtual https origin
 * (https://appassets.androidplatform.net/) through shouldInterceptRequest, the same scheme
 * AndroidX WebViewAssetLoader uses. That gives the page a secure origin so ES modules,
 * import maps, localStorage and Web Audio behave exactly like on the web, with no
 * file:// restrictions and no network access.
 *
 * Written in plain Java (no AndroidX) so it builds with the minimal toolchain in build-apk.sh.
 */
public class MainActivity extends Activity {

    static final String HOST = "appassets.androidplatform.net";
    static final String ORIGIN = "https://" + HOST + "/";
    static final String START_URL = ORIGIN + "index.html";

    private WebView web;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        Window w = getWindow();
        w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED);

        web = new WebView(this);
        web.setBackgroundColor(0xFF1A1E5A);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.setVerticalScrollBarEnabled(false);
        web.setHorizontalScrollBarEnabled(false);
        web.setHapticFeedbackEnabled(false);
        web.setLongClickable(false);
        web.setOnLongClickListener(new View.OnLongClickListener() {
            public boolean onLongClick(View v) { return true; }
        });

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setTextZoom(100); // ignore system font scaling; the HUD is laid out in CSS px
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setUserAgentString(s.getUserAgentString() + " TurboKartRallyApp/" + versionName());

        web.setWebViewClient(new AssetWebViewClient(this, getAssets()));
        web.setWebChromeClient(new WebChromeClient());

        setContentView(web);
        enterImmersiveMode();

        if (savedInstanceState == null || web.restoreState(savedInstanceState) == null) {
            web.loadUrl(START_URL);
        }
    }

    private String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "1";
        }
    }

    @SuppressWarnings("deprecation")
    void enterImmersiveMode() {
        View decor = getWindow().getDecorView();
        decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) enterImmersiveMode();
    }

    @Override
    protected void onPause() {
        if (web != null) {
            web.evaluateJavascript("window.__tkrAppPause && window.__tkrAppPause();", null);
            web.onPause();
            web.pauseTimers();
        }
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) {
            web.resumeTimers();
            web.onResume();
            web.evaluateJavascript("window.__tkrAppResume && window.__tkrAppResume();", null);
        }
        enterImmersiveMode();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        if (web != null) web.saveState(outState);
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.stopLoading();
            web.setWebViewClient(new WebViewClient());
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }

    /** Back: pause in a race, step back through menus, leave the app from the title screen. */
    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        if (web == null) { super.onBackPressed(); return; }
        web.evaluateJavascript("(window.__tkrBack ? window.__tkrBack() : 'exit')", new ValueCallback<String>() {
            public void onReceiveValue(String value) {
                if (value == null || value.indexOf("exit") >= 0) {
                    finish();
                }
            }
        });
    }

    /** Called when the WebView renderer crashes or is killed under memory pressure: restart cleanly. */
    void recreateWebView() {
        if (web != null) {
            android.view.ViewParent parent = web.getParent();
            if (parent instanceof android.view.ViewGroup) ((android.view.ViewGroup) parent).removeView(web);
            web.destroy();
            web = null;
        }
        recreate();
    }

    // ------------------------------------------------------------------------------------------

    static final class AssetWebViewClient extends WebViewClient {
        private final MainActivity activity;
        private final AssetManager assets;

        AssetWebViewClient(MainActivity activity, AssetManager assets) {
            this.activity = activity;
            this.assets = assets;
        }

        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (url == null || !"https".equals(url.getScheme()) || !HOST.equals(url.getHost())) {
                // Everything is bundled; refuse any other network request.
                return error(403, "Forbidden");
            }
            String path = url.getPath();
            if (path == null || path.length() == 0 || "/".equals(path)) path = "/index.html";
            if (path.indexOf("..") >= 0) return error(403, "Forbidden");
            try {
                InputStream in = assets.open("www" + path, AssetManager.ACCESS_STREAMING);
                String mime = mimeType(path);
                String encoding = mime.startsWith("text/") || mime.endsWith("javascript") || mime.endsWith("json") || mime.endsWith("svg+xml") ? "utf-8" : null;
                Map<String, String> headers = new HashMap<String, String>();
                headers.put("Cache-Control", "no-cache");
                headers.put("Access-Control-Allow-Origin", "*");
                return new WebResourceResponse(mime, encoding, 200, "OK", headers, in);
            } catch (IOException e) {
                return error(404, "Not Found");
            }
        }

        private static WebResourceResponse error(int code, String reason) {
            return new WebResourceResponse("text/plain", "utf-8", code, reason,
                    new HashMap<String, String>(), new ByteArrayInputStream(new byte[0]));
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (url != null && HOST.equals(url.getHost())) return false;
            // External links (if any) open in the browser instead of replacing the game.
            try {
                activity.startActivity(new Intent(Intent.ACTION_VIEW, url));
            } catch (Exception ignored) {
                // no browser available
            }
            return true;
        }

        @Override
        public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            activity.recreateWebView();
            return true;
        }

        static String mimeType(String path) {
            String p = path.toLowerCase();
            if (p.endsWith(".html") || p.endsWith(".htm")) return "text/html";
            if (p.endsWith(".js") || p.endsWith(".mjs")) return "text/javascript";
            if (p.endsWith(".css")) return "text/css";
            if (p.endsWith(".json") || p.endsWith(".map")) return "application/json";
            if (p.endsWith(".svg")) return "image/svg+xml";
            if (p.endsWith(".png")) return "image/png";
            if (p.endsWith(".jpg") || p.endsWith(".jpeg")) return "image/jpeg";
            if (p.endsWith(".webp")) return "image/webp";
            if (p.endsWith(".gif")) return "image/gif";
            if (p.endsWith(".ico")) return "image/x-icon";
            if (p.endsWith(".woff2")) return "font/woff2";
            if (p.endsWith(".woff")) return "font/woff";
            if (p.endsWith(".ttf")) return "font/ttf";
            if (p.endsWith(".otf")) return "font/otf";
            if (p.endsWith(".wasm")) return "application/wasm";
            if (p.endsWith(".mp3")) return "audio/mpeg";
            if (p.endsWith(".ogg")) return "audio/ogg";
            if (p.endsWith(".wav")) return "audio/wav";
            if (p.endsWith(".m4a")) return "audio/mp4";
            if (p.endsWith(".mp4")) return "video/mp4";
            if (p.endsWith(".txt") || p.endsWith(".md")) return "text/plain";
            return "application/octet-stream";
        }
    }
}
