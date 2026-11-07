# stop-minio.sh

Stops the MinIO server [start-minio](start-minio.md) started for a manual test. It never fails, including when nothing is running.

Invoke from the repo root: `bun run stop-minio -- <name>`

- `<name>`: the name the server was started with.
