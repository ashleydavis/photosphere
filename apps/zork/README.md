# Zork (TypeScript)

Play the original **Zork I**, **Zork II**, and **Zork III** from the terminal or in your browser.

This app runs the MIT-licensed Infocom story files (opened by Microsoft / Activision via [historicalsource](https://github.com/historicalsource/zork1)) on a TypeScript [Z-machine](https://www.npmjs.com/package/zmachine). The original ZIL sources are vendored under `zil/` for study.

## Setup

From the monorepo root:

```bash
bun install
```

## Play in the terminal

From the monorepo root:

```bash
bun run --filter=zork play
```

Or from `apps/zork`:

```bash
cd apps/zork
bun run play          # Zork I (default)
bun run play -- zork1
bun run play -- zork2
bun run play -- zork3
bun run play -- 2     # same as zork2
bun run play -- help
```

In-game, type commands like `OPEN MAILBOX`, `GO NORTH`, `TAKE LAMP`, `INVENTORY`. Type `QUIT` to exit.

Saves are written to your home directory as `~/.zork-zork1.sav` (and similarly for II / III).

## Play in the browser

Start the Vite dev server:

```bash
# from repo root
bun run --filter=zork dev

# or from apps/zork
cd apps/zork
bun run dev
```

Open the URL Vite prints (default [http://localhost:5177](http://localhost:5177)).

- Landing page: pick **Zork I**, **II**, or **III**
- Deep link: `http://localhost:5177/?game=zork2`

### Build a static site to share

```bash
cd apps/zork
bun run build
bun run preview
```

`bun run build` writes a static site to `apps/zork/dist/`. Host that folder on any static file host (GitHub Pages, Netlify, S3, etc.). Asset paths are relative (`base: './'`), so it works from a subdirectory too.

## Develop

```bash
cd apps/zork
bun run test       # unit + story smoke tests
bun run compile    # TypeScript check
bun run build      # production web bundle
```

## Layout

| Path | Purpose |
| --- | --- |
| `src/cli.ts` | Terminal player entry |
| `src/main.ts` | Browser player entry |
| `src/terminal-io.ts` | stdin/stdout Z-machine adapter |
| `stories/*.z3` | Compiled Z-machine story files |
| `public/stories/*.z3` | Same stories served by Vite |
| `zil/` | Original ZIL sources (MIT) |
| `ATTRIBUTION.md` | License and credit notes |

## Why a Z-machine (not a hand rewrite)?

Infocom games were written in **ZIL** and compiled to **Z-machine** bytecode. Porting “the entire game” faithfully means running that bytecode on a TypeScript Z-machine—the same portability model Infocom used across 1980s platforms—rather than re-implementing thousands of lines of puzzle logic by hand.

## License

- App TypeScript code: MIT
- Bundled Zork story/ZIL materials: MIT (see `zil/*/LICENSE` and `ATTRIBUTION.md`)
- ZORK trademark remains with its owners
