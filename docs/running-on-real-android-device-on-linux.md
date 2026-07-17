# Running the App on a Physical Android Device (Linux)

This guide walks through connecting a physical Android device to Android Studio
on Linux and deploying the app to it. It covers the setup that most commonly
trips people up (cables, USB mode, and `adb` on your PATH).

## Prerequisites

- Android Studio installed, with the Android SDK present (typically at
  `~/Android/Sdk`).
- A **data-capable** USB cable. Many cables are charge-only and will silently
  fail to connect — this is the single most common cause of "device not
  detected".

## 1. Enable Developer Options on the device

1. Open **Settings**.
2. Go to **About phone** (may be under **System → About phone**).
3. Find **Build number** (sometimes under **Software information**).
4. Tap **Build number** seven times.
5. Enter your PIN/password if prompted.
6. You'll see **"You are now a developer!"**

## 2. Enable USB debugging

1. Go to **Settings → System → Developer options** (location varies by device).
2. Ensure the toggle at the top is **On**.
3. Under the **Debugging** section, turn on **USB debugging**.
4. Confirm the dialog that appears.

## 3. Make sure `adb` is available

Android Studio bundles `adb` in `~/Android/Sdk/platform-tools`. Check whether
it's on your PATH:

```bash
adb version
```

If you get `command not found`, add platform-tools to your PATH. For **zsh**:

```bash
echo 'export PATH=$PATH:$HOME/Android/Sdk/platform-tools' >> ~/.zshrc
source ~/.zshrc
```

For **bash**, use `~/.bashrc` instead of `~/.zshrc`.

Confirm it now resolves:

```bash
adb version
```

## 4. Connect the device

1. Plug the device into the computer, **directly** into a laptop/desktop port
   (avoid hubs/dongles for the first connection).
2. If the device prompts for a USB mode, choose **File Transfer (MTP)** — not
   "Charging only".
3. On the device, accept the **"Allow USB debugging?"** dialog. Tick
   **"Always allow from this computer"** for convenience.

## 5. Verify the connection

First confirm Linux sees the hardware at all:

```bash
lsusb
```

You should see a line for your device's manufacturer, e.g. a Pixel shows:

```
Bus 00X Device 00X: ID 18d1:4ee7 Google Inc. Nexus/Pixel Device (charging + debug)
```

Then confirm `adb` sees it:

```bash
adb devices
```

Expected output (the serial will differ; an emulator may also be listed):

```
List of devices attached
A1B2C3D4E5F6G7  device
emulator-5554   device
```

The status should read **`device`**.

## 6. Run from Android Studio

1. In the toolbar device dropdown (next to the **Run ▶** button), select your
   physical device — Android Studio shows a friendly name (e.g. "Google Pixel").
2. Press **Run ▶** to build and deploy to the hardware.

If it doesn't appear immediately, open the dropdown to refresh, or check
**Device Manager → Physical**.

## Troubleshooting

| Symptom | Likely cause & fix |
| --- | --- |
| Device missing from `lsusb` | Charge-only cable (swap it), wrong USB mode (set to File Transfer), or a flaky hub (plug in directly). |
| `adb devices` shows `unauthorized` | The "Allow USB debugging?" prompt wasn't accepted. Unlock the device and tap **Allow**. |
| `adb devices` shows `no permissions` | udev rule issue. Create `/etc/udev/rules.d/51-android.rules` with a rule for your vendor ID (e.g. `SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", GROUP="plugdev"`), then run `sudo udevadm control --reload-rules && sudo udevadm trigger`. Ensure your user is in the `plugdev` group. |
| Nothing shows in the Studio dropdown | Refresh the dropdown, or check **Device Manager → Physical**. Run `adb kill-server && adb start-server` to reset. |

## Bonus: Deploy over Wi-Fi (no cable)

Once a wired connection works, you can switch to wireless:

```bash
adb tcpip 5555
adb connect <phone-ip>:5555
```

Find `<phone-ip>` under **Settings → About phone → IP address** (or in your
Wi-Fi network details). After connecting, you can unplug the cable and deploy
over the network. To return to USB mode later, run `adb usb`.

> **Note:** On Android 11+ you can also use **Wireless debugging** with pairing
> codes, found directly in Developer options — no `tcpip` step required.