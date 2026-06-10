# Testing

Manual and automated test documentation for Photosphere.

## Running tests

Run all CLI smoke tests (from repo root):

```bash
bun run test:cli
```

Run a single CLI smoke test by number or name:

```bash
bun run test:cli -- 43
bun run test:cli -- replicate-partial
```

Run all unit tests:

```bash
bun run test
```

Run a single unit test by name or pattern:

```bash
bun run test -- <test-name-or-pattern>
```

Run performance benchmarks:

```bash
bun run perf
```

Capture desktop app screenshots headlessly (for UX review / docs):

```bash
bun run screenshots
```

## Structure

- [e2e/](e2e/) - End-to-end manual test scripts covering full user workflows
- [screenshots.md](screenshots.md) - Capturing desktop app screenshots via the test control server
