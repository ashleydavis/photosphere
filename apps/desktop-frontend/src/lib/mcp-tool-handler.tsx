import React, { useEffect } from "react";
import { useNavigate, type NavigateFunction } from "react-router-dom";
import type { IElectronAPI } from "electron-defs";
import { TaskQueue, TaskStatus } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { useAssetDatabase, useGallery, useSearch, type IGalleryItem } from "user-interface";

//
// IPC channel constants — kept in sync with apps/desktop/src/lib/mcp/ipc.ts.
//
const MCP_TOOL_REQUEST = "mcp-tool-request";

//
// Shape of the request payload sent by the MCP worker via the main process.
//
interface IMcpToolRequest {
    requestId: string;
    tool: string;
    args: Record<string, unknown>;
}

//
// Registers a renderer-side listener for MCP tool requests. Dispatches each tool to the
// appropriate frontend context and sends back a result via electronAPI.sendMcpToolResponse.
//
// Renders nothing; lives near the root of the component tree so it has access to the
// AssetDatabase and Gallery contexts.
//
export function McpToolHandler(): React.ReactElement | null {
    const assetDatabase = useAssetDatabase();
    const gallery = useGallery();
    const search = useSearch();
    const navigate = useNavigate();

    useEffect(() => {
        const electronAPI = (window as unknown as { electronAPI?: IElectronAPI }).electronAPI;
        if (!electronAPI) {
            return;
        }

        const handler = (request: IMcpToolRequest): void => {
            void dispatchTool(request, assetDatabase, gallery, search, navigate, electronAPI)
                .then(result => {
                    electronAPI.sendMcpToolResponse({ requestId: request.requestId, result });
                })
                .catch((error: unknown) => {
                    const message = error instanceof Error ? error.message : String(error);
                    electronAPI.sendMcpToolResponse({ requestId: request.requestId, error: message });
                });
        };

        electronAPI.onMessage(MCP_TOOL_REQUEST, handler);

        return () => {
            electronAPI.removeAllListeners(MCP_TOOL_REQUEST);
        };
    }, [ assetDatabase, gallery, search, navigate ]);

    return null;
}

//
// Dispatches a single tool call to the appropriate frontend context.
// Returns the textual result that gets surfaced to the MCP client.
//
async function dispatchTool(
    request: IMcpToolRequest,
    assetDatabase: ReturnType<typeof useAssetDatabase>,
    gallery: ReturnType<typeof useGallery>,
    search: ReturnType<typeof useSearch>,
    navigate: NavigateFunction,
    electronAPI: IElectronAPI,
): Promise<string> {
    switch (request.tool) {
        case "list_databases": {
            const databases = await electronAPI.getDatabases();
            return JSON.stringify(databases, null, 2);
        }
        case "open_database": {
            const args = request.args as { path: string };
            await assetDatabase.openDatabase(args.path);
            return `Opened database at ${args.path}`;
        }
        case "close_database": {
            await assetDatabase.closeDatabase();
            return "Closed database";
        }
        case "list_media_files": {
            //
            // Paginate over the in-memory loaded gallery using a numeric offset stored in pageId.
            //
            const args = request.args as { limit: number; pageId?: string };
            const sorted = gallery.allItems().slice().sort((firstItem, secondItem) => {
                const firstDate = firstItem.photoDate ? Date.parse(firstItem.photoDate) : 0;
                const secondDate = secondItem.photoDate ? Date.parse(secondItem.photoDate) : 0;
                return secondDate - firstDate;
            });
            const offset = args.pageId ? Number.parseInt(args.pageId, 10) : 0;
            const slice = sorted.slice(offset, offset + args.limit);
            const nextOffset = offset + slice.length;
            return JSON.stringify({
                mediaFiles: slice.map(toMediaFileSummary),
                nextPageId: nextOffset < sorted.length ? String(nextOffset) : undefined,
            }, null, 2);
        }
        case "get_media_file_info": {
            const args = request.args as { assetId: string };
            const item = gallery.getItemById(args.assetId);
            if (!item) {
                return `Media file ${args.assetId} not found.`;
            }
            return JSON.stringify(item, null, 2);
        }
        case "search_media_files": {
            const args = request.args as {
                query: string;
                contentType?: string;
                dateFrom?: string;
                dateTo?: string;
                limit: number;
            };
            //
            // Drive the GUI search bar so the user sees every match in the gallery.
            // The text query is what the GUI search understands; the other filters
            // (contentType, date range) narrow the result list returned to the model.
            // The GUI keeps all matches; only the wire payload to Claude is capped.
            //
            const query = args.query ?? "";
            //
            // Mirror the query into the search input box so the GUI shows what the model
            // searched for. The SearchContext's auto-sync only fires when the panel is
            // closed; we want the input to update either way.
            //
            search.setSearchInput(query);
            if (query.length > 0) {
                await gallery.search(query);
            }
            else {
                await gallery.clearSearch();
            }
            const candidates = query.length > 0 ? gallery.searchedItems() : gallery.allItems();
            const filtered = applyExtraFilters(candidates, args.contentType, args.dateFrom, args.dateTo);
            const top = filtered.slice(0, args.limit);
            return JSON.stringify({
                totalMatches: filtered.length,
                returned: top.length,
                mediaFiles: top.map(toMediaFileSummary),
            }, null, 2);
        }
        case "open_media_file": {
            const args = request.args as { assetId: string };
            const item = gallery.getItemById(args.assetId);
            if (!item) {
                return `Media file ${args.assetId} not found.`;
            }
            //
            // Mirror what a thumbnail click does: navigate to /gallery (no assetId in the URL)
            // and select the item directly. Routing /gallery/<id> instead would persist the id
            // in the URL, which the GalleryPage effect re-syncs onto selectedItemId — that
            // makes the asset-view close button unable to clear the selection.
            //
            navigate("/gallery");
            gallery.setSelectedItemId(args.assetId);
            return `Opened ${item.origFileName ?? args.assetId} in the gallery.`;
        }
        case "save_media_file": {
            const args = request.args as { assetId: string; outputPath: string; type: string };
            const databasePath = assetDatabase.databasePath;
            if (!databasePath) {
                return "No database is currently open in Photosphere.";
            }
            //
            // Pass outputPath as destPath so the save-asset IPC writes straight to it
            // (no dialog — the model has already chosen the destination via Claude).
            //
            const defaultFilename = args.outputPath.split(/[\\/]/).pop() || args.outputPath;
            await electronAPI.saveAsset(args.assetId, args.type, defaultFilename, databasePath, args.outputPath);
            return `Saving ${args.type} of media file ${args.assetId} to ${args.outputPath}`;
        }
        case "import_media_files": {
            const args = request.args as { paths: string[]; dryRun: boolean };
            if (args.dryRun) {
                return "Dry-run import is not supported from the desktop MCP server. Use `psi mcp` (CLI) for dry runs.";
            }
            const session = await electronAPI.importDirectories(args.paths);
            return session
                ? `Started import session ${session.sessionId}`
                : "Import cancelled or no database open.";
        }
        case "delete_media_file": {
            const args = request.args as { assetId: string };
            await gallery.deleteAsset(args.assetId);
            return `Deleted media file ${args.assetId}`;
        }
        case "update_media_file": {
            const args = request.args as { assetId: string; updates: Record<string, unknown> };
            await gallery.updateGalleryItem(args.assetId, args.updates);
            return `Updated media file ${args.assetId}`;
        }
        case "get_database_summary": {
            const databasePath = assetDatabase.databasePath;
            if (!databasePath) {
                return "No database is currently open in Photosphere.";
            }
            //
            // Reuse the same get-database-summary task that the desktop's Summary page uses.
            //
            const queue = new TaskQueue(new RandomUuidGenerator(), `mcp-summary-${databasePath}`);
            try {
                const taskId = queue.addTask("get-database-summary", { databasePath });
                const result = await queue.awaitTask(taskId);
                if (!result) {
                    return "Database summary task was cancelled.";
                }
                if (result.status !== TaskStatus.Succeeded) {
                    return `Database summary failed: ${result.errorMessage ?? "unknown error"}`;
                }
                return JSON.stringify(result.outputs, null, 2);
            }
            finally {
                queue.shutdown();
            }
        }
        case "verify_database":
            return "Verify is not yet supported from the desktop MCP server. Use `psi mcp` (CLI) for now.";
        default:
            return `Unknown MCP tool: ${request.tool}`;
    }
}

//
// Applies the optional contentType-prefix and date-range filters to a list of gallery items.
//
function applyExtraFilters(
    items: IGalleryItem[],
    contentType: string | undefined,
    dateFrom: string | undefined,
    dateTo: string | undefined,
): IGalleryItem[] {
    const contentTypePrefix = contentType ? contentType.toLowerCase() : undefined;
    const dateFromMs = dateFrom ? Date.parse(dateFrom) : undefined;
    const dateToMs = dateTo ? Date.parse(dateTo) : undefined;
    if (!contentTypePrefix && dateFromMs === undefined && dateToMs === undefined) {
        return items;
    }
    return items.filter(item => {
        if (contentTypePrefix && !(item.contentType || "").toLowerCase().startsWith(contentTypePrefix)) {
            return false;
        }
        if (dateFromMs !== undefined || dateToMs !== undefined) {
            if (!item.photoDate) {
                return false;
            }
            const photoMs = Date.parse(item.photoDate);
            if (Number.isNaN(photoMs)) {
                return false;
            }
            if (dateFromMs !== undefined && photoMs < dateFromMs) {
                return false;
            }
            if (dateToMs !== undefined && photoMs > dateToMs) {
                return false;
            }
        }
        return true;
    });
}

//
// Reduces a gallery item to the minimal summary returned by listing tools.
//
function toMediaFileSummary(item: IGalleryItem): Record<string, unknown> {
    return {
        _id: item._id,
        origFileName: item.origFileName,
        contentType: item.contentType,
        photoDate: item.photoDate,
        width: item.width,
        height: item.height,
        location: item.location,
        coordinates: item.coordinates,
    };
}
