# run-macos.sh

Builds the MacOS app (`build-macos.sh`) and launches it. Invoked as `bun run --filter=ziggy run:macos`. Takes no arguments. Runs on MacOS only. The launched process is recorded when it is started and stopped through `kill_process_tree` from `scripts/lib/process-control.sh`.
