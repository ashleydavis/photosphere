# run-windows.sh

Builds the Windows app (`build-windows.sh`) and launches it. Invoked as `bun run --filter=ziggy run:windows`. Takes no arguments. Runs on Windows. The launched process is recorded when it is started and stopped through `kill_process_tree` from `scripts/lib/process-control.sh`.
