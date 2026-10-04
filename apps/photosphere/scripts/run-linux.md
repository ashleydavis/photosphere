# run-linux.sh

Builds the Linux app (`build-linux.sh`) and launches it. Invoked as `bun run --filter=ziggy run:linux`. Takes no arguments. Runs on Linux. The launched process is recorded when it is started and stopped through `kill_process_tree` from `scripts/lib/process-control.sh`.
