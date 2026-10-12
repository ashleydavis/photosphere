# run-linux.sh

Builds the example's Linux app with `build-linux.sh` and runs it. Runs on Linux, and needs the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0` and `libwebkit2gtk-4.1-0`) and the GStreamer plugins WebKitGTK plays video with (`gstreamer1.0-plugins-good` and `gstreamer1.0-libav`), which most desktop distributions already have. No development packages are needed.

Arguments are passed to the app, so `-geometry=WxH` sets the window size.

## The web view's sandbox

WebKitGTK runs its web process in a bubblewrap sandbox, which needs the program to be allowed to create a user namespace. Some systems do not allow that to an ordinary program (Ubuntu's default restriction is one). Before it creates the web view the app runs the same bubblewrap setup WebKitGTK does. When that fails, the app says so on standard error ("the web view's sandbox cannot start on this system") and turns the sandbox off for that run, because the web view would not start otherwise. Where bubblewrap works the sandbox stays on. Setting `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` in the environment yourself is respected and skips the check.

## The graphics card

WebKitGTK draws with a graphics card it sets up through GBM and EGL, and aborts the whole program when that setup fails, which a card with a broken driver (one updated without a reboot, for example) makes it do. Before GTK starts, the app tries the same setup on each card in a child process, the card that started the display first, and tells WebKitGTK to use the first one it works on through `WEBKIT_WEB_RENDER_DEVICE_FILE`. Each card it skips is named on standard error. When it works on none, the app turns WebKitGTK's GPU drawing off with `WEBKIT_DISABLE_DMABUF_RENDERER` and the web view draws without a card. The check runs on every start, so a card that is fixed is used again the next time. Setting either variable in the environment yourself is respected and skips the check.
