# run-macos

Builds the MacOS app in Debug for this Mac's architecture with `build-macos.sh`, then runs its executable directly, so its output appears in the terminal.

Run it on a Mac in a graphical session: `mise exec -- bash apps/ziggy-example/scripts/run-macos.sh [app arguments]`.

## Arguments

Every argument goes to the app. `-geometry=WxH` sets the window size.
