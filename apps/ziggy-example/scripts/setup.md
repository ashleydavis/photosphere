# setup.sh

Runs the setup scripts that apply to this machine: iOS and Android on a Mac, Android on Linux, and Windows under Git Bash. Linux and Windows need nothing more than `mise install`, and the Windows script only fetches the pinned WebView2 SDK. No arguments. The root `bun run setup` reaches it through this package's `setup` script.
