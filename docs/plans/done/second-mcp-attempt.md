# Second MCP Attempt

## Overview

Build MCP (Model Context Protocol) server support for Photosphere in two forms:

1. **Embedded in the Electron desktop app** — an HTTP MCP server running in a utility process, started automatically when Electron launches. MCP clients connect to it at `http://localhost:<port>/mcp`. Every tool call is relayed via IPC to the renderer, which executes it using existing frontend contexts. The worker owns no database connection.

2. **`psi mcp` CLI command** — a stdio MCP server started on demand by the MCP client by spawning `psi mcp --db <path>`. Tools are registered inline and call `node-api` functions directly. No `mcp-tools` dependency.

The `packages/mcp-tools` package contains the `IMcpContext` interface, shared types, and `registerPhotosphereTools`. It is used only by the desktop app. The CLI registers tools directly against `node-api`.

---

## Steps

### 1. Create `packages/mcp-tools/package.json`

Create a new workspace package named `mcp-tools`. Depend on `api`, `storage`, `utils`, `node-utils`, and `bdb` (all workspace packages). Include `compile` and `test` scripts matching the convention used by other packages.

### 2. Create `packages/mcp-tools/src/types.ts`

Define all shared types:

- `IMcpDatabaseResult` — `{ bsonDatabase: IBsonDatabase, assetStorage: IStorage, databasePath: string, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, sessionId: string }`
- `IAssetSummary` — `{ _id: string, origFileName: string, contentType: string, photoDate?: string, width: number, height: number, location?: string, coordinates?: IAssetCoordinates }`
- `IAssetCoordinates` — `{ lat: number, lng: number }`
- `IKnownDatabase` — `{ name: string, path: string, description?: string }`
- `IAssetUpdates` — `{ description?: string, labels?: string[], photoDate?: string, location?: string }`
- `IMcpContext` — one method per tool, each returning `Promise<string>` (or `Promise<CallToolResult>` for image tools):
  - `isDatabaseOpen(): boolean`
  - `getDatabaseSummary(): Promise<string>`
  - `listAssets(limit: number, pageId: string | undefined): Promise<string>`
  - `getAssetInfo(assetId: string): Promise<string>`
  - `searchAssets(query: string, contentType: string | undefined, dateFrom: string | undefined, dateTo: string | undefined, limit: number): Promise<string>`
  - `exportAsset(assetId: string, outputPath: string, type: string): Promise<string>`
  - `importAssets(paths: string[], dryRun: boolean): Promise<string>`
  - `openDatabase(path: string): Promise<string>`
  - `closeDatabase(): string`
  - `listDatabases(): Promise<string>`
  - `deleteAsset(assetId: string): Promise<string>`
  - `updateAsset(assetId: string, updates: IAssetUpdates): Promise<string>`
  - `verifyDatabase(): Promise<string>`

### 3. Create `packages/mcp-tools/src/register-tools.ts`

Export `registerPhotosphereTools(server: McpServer, context: IMcpContext): void`.

Each tool is a one-liner that calls the matching `context` method and wraps the result with `textResult`. Define `textResult(text: string): CallToolResult` locally. All "no database open" guards live in the context, not here.

Tool list with Zod input schemas:

- `get_database_summary` — no inputs
- `list_assets` — `{ limit: z.number().int().min(1).max(200).default(20), pageId: z.string().optional() }`
- `get_asset_info` — `{ assetId: z.string() }`
- `search_assets` — `{ query: z.string().default(""), contentType: z.string().optional(), dateFrom: z.string().optional(), dateTo: z.string().optional(), limit: z.number().int().min(1).max(200).default(20) }`
- `export_asset` — `{ assetId: z.string(), outputPath: z.string(), type: z.enum(["original","display","thumb"]).default("original") }`
- `import_assets` — `{ paths: z.array(z.string()), dryRun: z.boolean().default(false) }`
- `open_database` — `{ path: z.string() }`
- `close_database` — no inputs
- `list_databases` — no inputs
- `delete_asset` — `{ assetId: z.string() }`
- `update_asset` — `{ assetId: z.string(), description: z.string().optional(), labels: z.array(z.string()).optional(), photoDate: z.string().optional(), location: z.string().optional() }`
- `verify_database` — no inputs

### 4. Export all from `packages/mcp-tools/src/index.ts`

Export all types and `registerPhotosphereTools`.

### 5. Update root `package.json` workspaces

Add `"packages/mcp-tools"` to the `workspaces` array. Run `bun install` from the repo root.

---

### Asset query functions in `node-api`

### 6. Add `packages/node-api/src/lib/asset-query.ts`

New file. Define `IListAssetsResult` interface: `{ assets: IAsset[], nextPageId?: string }`.

Implement and export:

- `listAssetPage(bsonDatabase: IBsonDatabase, limit: number, pageId: string | undefined): Promise<IListAssetsResult>` — queries `metadata` collection sorted by `photoDate` descending, returns a page of records and optional `nextPageId`.
- `searchAssets(bsonDatabase: IBsonDatabase, query: string, contentType: string | undefined, dateFrom: string | undefined, dateTo: string | undefined, limit: number): Promise<IAsset[]>` — in-memory filter: case-insensitive substring on `origFileName` and `location`, prefix on `contentType`, date range on `photoDate`.
- `getAsset(bsonDatabase: IBsonDatabase, assetId: string): Promise<IAsset | undefined>` — returns a single asset by ID.
- `streamAssetToFile(assetStorage: IStorage, assetId: string, outputPath: string, type: string): Promise<number>` — maps type to storage key (`asset/`, `display/`, `thumb/`), streams to `outputPath` via `pipeline` from `stream/promises`, creates parent dirs, returns bytes written.

Export all from `packages/node-api/src/index.ts`.

---

### Electron desktop app (HTTP transport)

### 7. Add dependencies to `apps/desktop/package.json`

Add `"@modelcontextprotocol/sdk": "^1.0.0"` and `"mcp-tools": "workspace:*"` to `dependencies`.

### 8. Define IPC message types in `apps/desktop/src/mcp-ipc.ts`

New file. Channel name constants `MCP_TOOL_REQUEST = "mcp-tool-request"` and `MCP_TOOL_RESPONSE = "mcp-tool-response"`.

```ts
export interface IMcpToolRequest {
    requestId: string;
    tool: string;
    args: Record<string, unknown>;
}

export interface IMcpToolResponse {
    requestId: string;
    result?: string;
    error?: string;
}
```

### 9. Create `apps/desktop/src/mcp-context.ts`

Export `DesktopMcpContext` implementing `IMcpContext`.

Constructor takes `sendRequest: (tool: string, args: object) => Promise<string>`. Each tool method calls `this.sendRequest(toolName, args)`.

Tracks `databaseOpen: boolean` internally. Expose `setDatabaseOpen(value: boolean): void`. Methods that require an open database return `"No database is currently open in Photosphere."` if `!this.databaseOpen`.

### 10. Create `apps/desktop/src/mcp-server.ts`

Export `createMcpServer(context: IMcpContext): McpServer`. Creates a `McpServer`, calls `registerPhotosphereTools`, returns it.

### 11. Create `apps/desktop/src/mcp-worker.ts`

Electron utility process entry point.

Export message type interfaces: `IMcpWorkerStartMessage` (includes `port: number`), `IMcpWorkerStopMessage`, `IMcpWorkerDatabaseOpenedMessage`, `IMcpWorkerDatabaseClosedMessage`.

Maintain a `pendingRequests: Map<string, (result: string) => void>`.

`sendRequest(tool, args)`: generates a `requestId` via `randomUUID()`, stores resolver in the map, posts `{ type: 'mcp-tool-request', requestId, tool, args }` to `parentPort`, returns a Promise that resolves when the response arrives.

On `parentPort` message `mcp-tool-response`: resolve the matching pending promise by `requestId`.

On `"start"`: create `DesktopMcpContext(sendRequest)`, call `createMcpServer(context)`, mount at `POST /mcp` and `GET /mcp` using `StreamableHTTPServerTransport` from `@modelcontextprotocol/sdk/server/streamableHttp.js`, listen on the provided port. Send `{ type: "server-ready" }` once listening, `{ type: "server-error" }` on failure.

On `"database-opened"`: call `context.setDatabaseOpen(true)`.
On `"database-closed"`: call `context.setDatabaseOpen(false)`.
On `"stop"`: close the HTTP server.

### 12. Add MCP request forwarding in `apps/desktop/src/main.ts`

`ipcMain.on(MCP_TOOL_REQUEST, ...)` forwards to `mainWindow.webContents.send`.
`ipcMain.on(MCP_TOOL_RESPONSE, ...)` forwards to `mcpWorker.postMessage`.

Add `write-file` handler: `ipcMain.handle('write-file', ...)` accepts a path and `Uint8Array`, creates parent directories, writes bytes to disk.

### 13. Add IPC handler in the renderer

New file in the desktop frontend package. Registers a listener on `MCP_TOOL_REQUEST`. Dispatches each tool to the appropriate frontend context method and sends back `MCP_TOOL_RESPONSE`.

Wire it up inside a React component near the root of the component tree so it has access to all contexts.

Tool dispatch map:
- `get_database_summary` → asset count, path, size from `AssetDatabase`
- `list_assets` → `GalleryContext` pagination
- `get_asset_info` → `GalleryContext.getItemById`
- `search_assets` → `GalleryContext.search` + client-side filter
- `export_asset` → `GalleryContext.loadAsset` + `ipcRenderer.invoke('write-file', path, bytes)`
- `import_assets` → queue an `import-assets` task via the existing task queue
- `open_database` → `AssetDatabase.openDatabase(path)`
- `close_database` → `AssetDatabase.closeDatabase()`
- `list_databases` → `ipcRenderer.invoke('get-databases')`
- `delete_asset` → `GalleryContext.deleteAsset`
- `update_asset` → `GalleryContext.updateGalleryItem`
- `verify_database` → queue a `verify-database` task and await its result

### 14. Update `apps/desktop/src/main.ts`

Add `initMcpServer()` alongside `initRestApi()`:
- Find a port via `findAvailablePort()`, store as `mcpPort`.
- Fork `bundle/mcp-worker.js`, send `"start"` with `port` on spawn, restart on non-zero exit unless shutting down.
- In `notify-database-opened` IPC handler: post `{ type: "database-opened" }` to MCP worker.
- In `notify-database-closed` IPC handler: post `{ type: "database-closed" }` to MCP worker.
- Add `mcpWorker: UtilityProcess | null` and clean it up in `before-quit`.
- Call `initMcpServer()` in `app.whenReady()` alongside `initRestApi()`.

### 15. Expose MCP port to the renderer

Add `ipcMain.handle('get-mcp-port', ...)` returning `mcpPort`. Expose `getMcpPort(): Promise<number>` via `contextBridge` in `preload.ts`.

### 16. Display MCP address in the About page

In the existing About page component, call `getMcpPort()` and display the MCP server address (`http://localhost:<port>/mcp`) with a copy button and a short note on how to add it to a Claude config.

---

### CLI (`psi mcp` command, stdio transport)

### 17. Add `packages/node-api/src/lib/asset-query.ts` functions to `node-api` dependencies in `apps/cli/package.json`

Ensure `node-api` is already a dependency (it should be). No new dependency needed.

### 18. Create `apps/cli/src/cmd/mcp.ts`

Implement `mcpCommand`. It should:
- Accept `ICommandContext` and `IMcpCommandOptions extends IBaseCommandOptions`.
- Do **NOT** take `--db`. The MCP client cannot be configured per-database; instead the model picks one via `list_databases` / `open_database` at runtime. The server starts with no database open.
- Maintain an in-process "current database" handle (initially `undefined`). Methods that need an open database return `"No database is currently open. Use list_databases / open_database first."` until one is opened.
- Create a `McpServer` from `@modelcontextprotocol/sdk/server/mcp.js`, register all tools inline using Zod schemas identical to `register-tools.ts`. Each tool calls the corresponding `api` function directly against the current database handle:
  - `get_database_summary` → `getDatabaseSummary(assetStorage)`
  - `list_assets` → `listAssetPage(bsonDatabase, limit, pageId)`
  - `get_asset_info` → `getAsset(bsonDatabase, assetId)`
  - `search_assets` → `searchAssets(bsonDatabase, query, contentType, dateFrom, dateTo, limit)`
  - `export_asset` → `streamAssetToFile(assetStorage, assetId, outputPath, type)`
  - `import_assets` → `addPaths(...)`
  - `verify_database` → `verify(...)`
  - `list_databases` → `getDatabases()`
  - `open_database` → resolve the requested entry via `getDatabases()` (match by name or path), then call `loadDatabase(...)` and store the result as the current handle. Returns a confirmation string.
  - `close_database` → drop the current handle (without persisting any global state) and return a confirmation string.
  - `delete_asset` / `update_asset` → omit from CLI (desktop-only for now)
- Start with `StdioServerTransport`. Print `Photosphere MCP server running` to `stderr`.
- Keep the process alive until stdin closes, then call `server.close()` and `exit(0)`.

### 19. Register `psi mcp` in `apps/cli/index.ts`

```ts
program
    .command("mcp")
    .description("Start an MCP server (stdio transport). The MCP client chooses which database to open at runtime via list_databases / open_database.")
    .option(...verboseOption)
    .option(...yesOption)
    .option(...cwdOption)
    .action(initContext(mcpCommand));
```

Note: `--db` and `--key` are deliberately omitted. Encryption keys for specific databases are still resolved through the existing vault entries (set up via `psi dbs add` / `psi secrets`) when `open_database` is called.

---

### Wiki documentation

### 20. Create `photosphere.wiki/Claude-Integration.md`

Write a new wiki page covering:

**How it works** — brief explanation of the MCP server. Include a Mermaid diagram:

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
        psi["psi mcp"]
    end
    db[("Media database")]
    cc -->|"HTTP"| mcp_http
    cc -->|"stdio"| psi
    mcp_http --> db
    psi --> db
```

**Integration instructions** — two sections, one per transport.

**What you can do** — concrete example prompts grouped by category (exploring, searching, getting details, exporting, importing).

**Link** from `Home.md` under a new "Claude Integration" heading.

---

## Unit Tests

- `packages/mcp-tools/src/test/register-tools.test.ts` — verify each tool calls the matching `IMcpContext` method with correct args; verify `isDatabaseOpen() === false` causes tools to return the "no database open" message.
- `packages/node-api/src/test/asset-query.test.ts` — one test per new function using an in-memory database.
- `apps/desktop/src/test/mcp-context.test.ts` — mock `sendRequest`, verify correct tool name and args are forwarded for each method.
- `apps/desktop/src/test/mcp-server.test.ts` — verify `registerPhotosphereTools` is called with the context; verify `isDatabaseOpen() === false` produces "no database open" response.

## Verify

```
bun run compile
bun run test
```

## Notes

- **No duplication**: `mcp-tools` provides the `IMcpContext` interface and `registerPhotosphereTools` for the desktop only. The CLI registers tools inline and calls `node-api` directly. `node-api` contains the shared query logic (`listAssetPage`, `searchAssets`, `getAsset`, `streamAssetToFile`).
- **IPC chain (desktop)**: MCP client → MCP worker → main process → renderer → main process → MCP worker → MCP client. Main is a stateless broker.
- **HTTP vs stdio**: HTTP (Streamable HTTP) is used in Electron because the worker can't own stdin/stdout. Stdio is used in the CLI because the MCP client spawns it as a child process.
- **Single database at a time**: Electron reflects whichever database is open via `setDatabaseOpen`. The CLI starts with no database open and lets the MCP client pick one at runtime via `list_databases` / `open_database` (so a single MCP client config can switch between any configured database).
- **`delete_asset` and `update_asset`**: Desktop-only for now; omit from CLI. Add later following the same pattern.
