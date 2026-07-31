# MCP Server Prototype for Photosphere

## Overview

Build MCP (Model Context Protocol) server support for Photosphere in two forms that share the same tool implementations:

1. **Embedded in the Electron desktop app** — an HTTP MCP server running in a utility process, started automatically when Electron launches. MCP clients connect to it at `http://localhost:<port>/mcp`. It is always aware of whichever database is currently open in Electron.

2. **`psi mcp` CLI command** — a stdio MCP server started on demand by the MCP client (Claude Desktop, Claude Code, etc.) by spawning `psi mcp --db <path>`. It runs for the lifetime of the client session and exits when the client closes.

The six MCP tool handler functions (`get_database_summary`, `list_assets`, `get_asset_info`, `search_assets`, `export_asset`, `add_assets`) are extracted into a shared `packages/mcp-tools` package so both the desktop app and the CLI import the same implementations.

## Issues

<!-- Populated later by plan:check -->

## Steps

### 1. Create `packages/mcp-tools/package.json`

Create a new workspace package named `mcp-tools`. It should depend on `api`, `storage`, `utils`, `node-utils`, and `bdb` (all workspace packages). Include `compile` and `test` scripts matching the convention used by other packages.

### 2. Create `packages/mcp-tools/src/types.ts`

Define the shared types used by all tool handlers:
- `IMcpDatabaseResult` interface: `{ bsonDatabase, assetStorage, databasePath: string, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, sessionId: string }`
- `IAssetSummary` interface: `{ _id, origFileName, contentType, photoDate, width, height, location, coordinates }`

### 3. Create `packages/mcp-tools/src/get-summary.ts`

Implement `getSummaryToolHandler(db: IMcpDatabaseResult): Promise<string>`. It should:
- Call `getDatabaseSummary(db.assetStorage)` from `api`
- Return a text response: total files, total size (formatted), database version, root hash

### 4. Create `packages/mcp-tools/src/list-assets.ts`

Implement `listAssetsToolHandler(db: IMcpDatabaseResult, limit: number, pageId: string | undefined): Promise<string>`. It should:
- Query `metadataCollection.sortIndex("photoDate", "desc").getPage(pageId)`
- Slice to `limit` records (max 200)
- Return JSON string: `{ assets: IAssetSummary[], nextPageId: string | undefined }`

### 5. Create `packages/mcp-tools/src/get-asset.ts`

Implement `getAssetToolHandler(db: IMcpDatabaseResult, assetId: string): Promise<string>`. It should:
- Call `metadataCollection.getOne(assetId)`
- Return the full `IAsset` record serialised as JSON, or an error string if not found

### 6. Create `packages/mcp-tools/src/search-assets.ts`

Implement `searchAssetsToolHandler(db: IMcpDatabaseResult, query: string, contentType: string | undefined, dateFrom: string | undefined, dateTo: string | undefined, limit: number): Promise<string>`. It should:
- Iterate pages from `sortIndex("photoDate", "desc")` with in-memory filtering: case-insensitive substring match on `origFileName` and `location`, prefix match on `contentType`, date range on `photoDate`
- Stop when `limit` results are collected or all pages exhausted
- Return JSON array of `IAssetSummary`

### 7. Create `packages/mcp-tools/src/export-asset.ts`

Implement `exportAssetToolHandler(db: IMcpDatabaseResult, assetId: string, outputPath: string, type: "original" | "display" | "thumb"): Promise<string>`. It should:
- Verify the asset exists in `metadataCollection`
- Map type to storage key: `asset/${assetId}`, `display/${assetId}`, `thumb/${assetId}`
- Stream from `assetStorage` to `outputPath` using `pipeline` from `stream/promises`
- Return a success message with output path and file size

### 8. Create `packages/mcp-tools/src/add-assets.ts`

Implement `addAssetsToolHandler(db: IMcpDatabaseResult, paths: string[], dryRun: boolean): Promise<string>`. It should:
- Call `addPaths` from `api` using `db.uuidGenerator`, `db.timestampProvider`, `db.sessionId`, and `db.databasePath`
- Return a text summary: files added, files skipped, errors

### 9. Export all from `packages/mcp-tools/src/index.ts`

Export all tool handlers and types from a single `index.ts` entry point.

### 10. Update root `package.json` workspaces

Add `"packages/mcp-tools"` to the `workspaces` array. Run `bun install` from the repo root.

---

### Electron desktop app (HTTP transport)

### 11. Add dependencies to `apps/desktop/package.json`

Add `"@modelcontextprotocol/sdk": "^1.0.0"` and `"mcp-tools": "workspace:*"` to `dependencies`.

### 12. Create `apps/desktop/src/mcp-database.ts`

Implement `openMcpDatabase(databasePath: string): Promise<IMcpDatabaseResult>`. It should:
- Create storage via `createStorage(databasePath)` from `storage`
- Open `BsonDatabase` via `createDatabase` from `api`
- Return an `IMcpDatabaseResult` populated with `RandomUuidGenerator`, `TimestampProvider`, and `randomUUID()` from `node:crypto`

### 13. Create `apps/desktop/src/mcp-server.ts`

Create the MCP server logic. It should:
- Import `McpServer` from `@modelcontextprotocol/sdk/server/mcp.js`
- Export `createMcpServer(): IMcpServerHandle` which creates a single `McpServer`, registers all six tools delegating to the handler functions from `mcp-tools`
- Export `IMcpServerHandle` with `setDatabase(db: IMcpDatabaseResult | undefined): void` and `mcpServer: McpServer`
- Each tool returns `"No database is currently open in Photosphere."` when the database is `undefined`

### 14. Create `apps/desktop/src/mcp-worker.ts`

Create a new Electron utility process entry point modelled on `rest-api-worker.ts`. It should:
- Export message type interfaces: `IMcpWorkerStartMessage`, `IMcpWorkerStopMessage`, `IMcpWorkerDatabaseOpenedMessage` (`databasePath: string`), `IMcpWorkerDatabaseClosedMessage`
- On `"start"`: create an Express HTTP server mounting the MCP handler at `POST /mcp` and `GET /mcp` using `StreamableHTTPServerTransport` from `@modelcontextprotocol/sdk/server/streamableHttp.js`
- On `"database-opened"`: call `openMcpDatabase(databasePath)` then `server.setDatabase(db)`
- On `"database-closed"`: call `server.setDatabase(undefined)`
- On `"stop"`: close the HTTP server
- Send `{ type: "server-ready" }` once listening, `{ type: "server-error" }` on failure

### 15. Update `apps/desktop/src/main.ts`

Add `initMcpServer()` alongside `initRestApi()`, following the same pattern:
- Find a port via `findAvailablePort()`, store as `mcpPort`
- Fork `bundle/mcp-worker.js`, send `"start"` on spawn, restart on non-zero exit unless shutting down
- In the `notify-database-opened` IPC handler: post `{ type: "database-opened", databasePath }` to the MCP worker
- In the `notify-database-closed` IPC handler: post `{ type: "database-closed" }` to the MCP worker
- Add `mcpWorker: UtilityProcess | null` and clean it up in `before-quit`
- Call `initMcpServer()` in `app.whenReady()` alongside `initRestApi()`

### 16. Expose MCP port to the renderer

Add `ipcMain.handle('get-mcp-port', ...)` returning `mcpPort`. Expose `getMcpPort(): Promise<number>` via `contextBridge` in `preload.ts`.

### 17. Display MCP address in the About page

In the existing About page component, call `getMcpPort()` and display the MCP server address (`http://localhost:<port>/mcp`) with a copy button and a short note on how to add it to a Claude config.

---

### CLI (`psi mcp` command, stdio transport)

### 18. Add dependencies to `apps/cli/package.json`

Add `"@modelcontextprotocol/sdk": "^1.0.0"` and `"mcp-tools": "workspace:*"` to `dependencies`.

### 19. Create `apps/cli/src/cmd/mcp.ts`

Implement `mcpCommand`. It should:
- Accept `ICommandContext` and `IMcpCommandOptions` (extends `IBaseCommandOptions`, no extra fields)
- Call `loadDatabase` from `init-cmd.ts` using the `--db` option (same as every other command)
- Build an `IMcpDatabaseResult` from the loaded database, using `context.uuidGenerator`, `context.timestampProvider`, `context.sessionId`
- Create an `McpServer` from `@modelcontextprotocol/sdk/server/mcp.js`, register all six tools delegating to the handler functions from `mcp-tools`
- Start the server with `StdioServerTransport` from `@modelcontextprotocol/sdk/server/stdio.js`
- Print `Photosphere MCP server running` to `stderr` (stdout is reserved for the MCP protocol)
- Keep the process alive until stdin closes

### 20. Register `psi mcp` in `apps/cli/index.ts`

Add the command to the program:
```
program
    .command("mcp")
    .description("Start an MCP server for the media file database (stdio transport).")
    .option(...dbOption)
    .option(...keyOption)
    .option(...verboseOption)
    .option(...yesOption)
    .option(...cwdOption)
    .action(initContext(mcpCommand));
```

### 21. Update integration instructions

Create `apps/cli/MCP_INTEGRATION.md` documenting:
- **Claude Desktop / Claude Code (via CLI)**: `command: "psi"`, `args: ["mcp", "--db", "/path/to/db"]`
- **Claude Desktop / Claude Code (via Electron)**: `type: "http"`, `url: "http://localhost:<port>/mcp"` (port shown in Electron About page)
- When to use each: CLI is best when Electron is not running or in headless/server environments; Electron is best for desktop users who already have the app open

---

### Wiki documentation

### 22. Create `photosphere.wiki/Claude-Integration.md`

Write a new wiki page covering:

**How it works** — a brief explanation that Photosphere exposes an MCP server that Claude-compatible clients can connect to, giving Claude read/write access to the media database. Include a Mermaid diagram showing both transport modes:

```
flowchart LR
    subgraph client["MCP Client (Claude)"]
        cc["Claude Code / Claude Desktop"]
    end
    subgraph desktop["Photosphere Desktop"]
        electron["Electron app"]
        mcp_http["MCP server\n(HTTP :port/mcp)"]
        electron --> mcp_http
    end
    subgraph cli["Photosphere CLI"]
        psi["psi mcp --db &lt;path&gt;"]
    end
    db[("Media database")]
    cc -->|"HTTP"| mcp_http
    cc -->|"stdio"| psi
    mcp_http --> db
    psi --> db
```

**Integration instructions** — two sections, one for each transport:
- *Desktop app*: how to find the MCP address on the About page, and the config block to paste into Claude Desktop or Claude Code
- *CLI*: the `psi mcp --db <path>` config block to paste into Claude Desktop or Claude Code

**What you can do** — a section with concrete examples of prompts the user can give Claude once connected, grouped by category:

- *Exploring your library*: "How many photos and videos are in my database?", "List my 10 most recent photos", "What photos do I have from 2022?"
- *Searching*: "Find all photos taken in Paris", "Show me videos from my holiday", "Find photos taken in January 2023"
- *Getting details*: "Tell me everything about asset `<id>`", "What are the GPS coordinates of this photo?"
- *Exporting*: "Export the original of asset `<id>` to ~/Downloads/photo.jpg", "Save the thumbnail of asset `<id>` to /tmp/thumb.jpg"
- *Adding files*: "Add all the photos in ~/Pictures/Holiday to my Photosphere database", "Do a dry run of adding ~/Desktop/new-photos so I can see what would be imported"

**Link to this page** from `Home.md` under a new "Claude Integration" heading in the Quick Links section.

## Unit Tests

- `packages/mcp-tools/src/test/get-summary.test.ts` — mock `getDatabaseSummary`, verify text output
- `packages/mcp-tools/src/test/list-assets.test.ts` — mock `sortIndex().getPage()`, verify JSON shape, limit, and `nextPageId`
- `packages/mcp-tools/src/test/get-asset.test.ts` — mock `metadataCollection.getOne`, verify hit and miss cases
- `packages/mcp-tools/src/test/search-assets.test.ts` — mock paginated results, verify filename, contentType, and date filters
- `packages/mcp-tools/src/test/export-asset.test.ts` — mock `assetStorage` stream, verify file written to `outputPath`
- `packages/mcp-tools/src/test/add-assets.test.ts` — mock `addPaths`, verify summary for add, skip, and dry-run cases
- `apps/desktop/src/test/mcp-server.test.ts` — verify `setDatabase(undefined)` causes all tools to return the "no database open" error

## Smoke Tests

**Electron (HTTP):**
1. Run `bun run dev`. Open Electron DevTools and confirm no MCP worker errors.
2. Open a database. Navigate to About page. Confirm the MCP address is displayed.
3. Add `{ "type": "http", "url": "http://localhost:<port>/mcp" }` to Claude Code's `.claude/settings.json`. Run `/mcp` and confirm `photosphere` shows `connected`.
4. Ask "How many photos?" — confirm `get_database_summary` is called.
5. Close the database in Electron, ask again — confirm "No database is currently open" response.

**CLI (stdio):**
6. Add `{ "command": "psi", "args": ["mcp", "--db", "./test/db"] }` to Claude Code's `.claude/settings.json`. Run `/mcp` and confirm `photosphere` shows `connected`.
7. Ask "List the 5 most recent photos" — confirm `list_assets` is called with `limit: 5`.
8. Ask "Find photos from Paris" — confirm `search_assets` is called with `query: "Paris"`.
9. Ask Claude to export an asset to `/tmp/test.jpg` — confirm the file is written.
10. Ask Claude to add a directory of photos — confirm `add_assets` is called and reports a result.

**Wiki:**
11. Open `photosphere.wiki/Claude-Integration.md` on GitHub and confirm the Mermaid diagram renders correctly.
12. Follow the integration instructions in the wiki from scratch on a clean machine — confirm the config blocks are accurate and complete.
13. Run each example prompt from the "What you can do" section against a real database and confirm they all produce sensible responses.

## Verify

- `cd packages/mcp-tools && bun run compile` — compiles with zero errors
- `cd packages/mcp-tools && bun run test` — all unit tests pass
- `cd apps/desktop && bun run compile` — compiles with zero errors
- `cd apps/cli && bun run compile` — compiles with zero errors
- `bun install` from repo root — no dependency errors
- `/mcp` in Claude Code shows `photosphere` as `connected` for both transport modes

## Notes

- **Shared tool package**: `packages/mcp-tools` contains all tool handler logic. Neither `apps/desktop` nor `apps/cli` duplicate it. Adding a new tool means editing only `packages/mcp-tools` and re-registering it in each server.
- **HTTP vs stdio**: HTTP (Streamable HTTP) is used in Electron because the server is a long-lived embedded process that can't own stdin/stdout. Stdio is used in the CLI because the MCP client spawns it as a child process. Both transports are supported by Claude Desktop, Claude Code, and other MCP clients.
- **Single database at a time**: The MCP server reflects whichever database is open. The CLI takes it via `--db`; Electron takes it from the currently open database via IPC.
- **S3 and encrypted databases**: `openMcpDatabase` in `apps/desktop` initially supports local filesystem only. S3 and encrypted databases can be added in a follow-up by extending the `database-opened` IPC message to include resolved secrets.
- **Claude Web / Cowork**: Both require a publicly reachable URL. The Electron HTTP server only listens on `localhost`. Adding a tunnel option is a natural follow-up.
