import { createMcpServer } from "../lib/mcp/server";

//
// Accesses a registered tool's handler from the McpServer private registry, so we can
// invoke it without spinning up a transport.
//
function getToolHandler(server: ReturnType<typeof createMcpServer>, name: string): (args: any) => Promise<{ content: Array<{ type: string; text: string }> }> {
    const registered = (server as unknown as { _registeredTools: Record<string, { handler: (args: any) => Promise<any> }> })._registeredTools[name];
    if (!registered) {
        throw new Error(`Tool ${name} not registered`);
    }
    return registered.handler;
}

describe("createMcpServer", () => {

    test("registers the full Photosphere tool set", () => {
        const server = createMcpServer(async () => "");

        const tools = Object.keys((server as unknown as { _registeredTools: Record<string, unknown> })._registeredTools);
        expect(tools).toEqual(expect.arrayContaining([
            "get_database_summary",
            "list_media_files",
            "get_media_file_info",
            "search_media_files",
            "save_media_file",
            "open_media_file",
            "import_media_files",
            "open_database",
            "close_database",
            "list_databases",
            "delete_media_file",
            "update_media_file",
            "verify_database",
        ]));
    });

    test("each tool forwards its name and args to sendRequest", async () => {
        const calls: Array<{ tool: string; args: Record<string, unknown> }> = [];
        const sendRequest = async (tool: string, args: Record<string, unknown>): Promise<string> => {
            calls.push({ tool, args });
            return `ok:${tool}`;
        };
        const server = createMcpServer(sendRequest);

        await getToolHandler(server, "get_database_summary")({});
        await getToolHandler(server, "list_media_files")({ limit: 5, pageId: "page-1" });
        await getToolHandler(server, "get_media_file_info")({ assetId: "asset-1" });
        await getToolHandler(server, "search_media_files")({ query: "x", limit: 10 });
        await getToolHandler(server, "save_media_file")({ assetId: "asset-1", outputPath: "/tmp/x", type: "display" });
        await getToolHandler(server, "open_media_file")({ assetId: "asset-1" });
        await getToolHandler(server, "import_media_files")({ paths: [ "/p" ], dryRun: false });
        await getToolHandler(server, "open_database")({ path: "/db" });
        await getToolHandler(server, "close_database")({});
        await getToolHandler(server, "list_databases")({});
        await getToolHandler(server, "delete_media_file")({ assetId: "asset-1" });
        await getToolHandler(server, "update_media_file")({ assetId: "asset-1", description: "new" });
        await getToolHandler(server, "verify_database")({});

        expect(calls.map(call => call.tool)).toEqual([
            "get_database_summary",
            "list_media_files",
            "get_media_file_info",
            "search_media_files",
            "save_media_file",
            "open_media_file",
            "import_media_files",
            "open_database",
            "close_database",
            "list_databases",
            "delete_media_file",
            "update_media_file",
            "verify_database",
        ]);
        expect(calls[1].args).toEqual({ limit: 5, pageId: "page-1" });
        expect(calls[4].args).toEqual({ assetId: "asset-1", outputPath: "/tmp/x", type: "display" });
        expect(calls[5].args).toEqual({ assetId: "asset-1" });
        expect(calls[11].args).toEqual({ assetId: "asset-1", description: "new" });
    });

    test("wraps sendRequest's reply in a text content block", async () => {
        const sendRequest = async (): Promise<string> => "the-reply";
        const server = createMcpServer(sendRequest);

        const result = await getToolHandler(server, "list_databases")({});

        expect(result.content).toEqual([
            { type: "text", text: "the-reply" },
        ]);
    });
});
