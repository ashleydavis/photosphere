---
description: Run the full test set (`bun run test:everything`) and report the result.
---

# Run test:everything

1. Run `bun run test:everything` from the repo root, through mise, as a background command. Pass no flags: no `--force` unless the human asked for it in the message that started this command.
2. When it finishes, report whether it passed (exit code 0) and, if it failed, name each failing suite and test with its error in one line. Change nothing and fix nothing.
