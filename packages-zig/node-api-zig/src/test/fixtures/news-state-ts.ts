//
// Runs the TypeScript news-state functions for the news-state.zig interop tests (PHOTOSPHERE_CONFIG_DIR is taken
// from the environment). Usage: bun run news-state-ts.ts load | add <id...> | set-version <version>
//
import { loadNewsState, addShownNewsIds, setLastShownUpdateVersion } from "../../../../../packages/node-api/src/lib/news-state";

const [command, ...rest] = process.argv.slice(2);
if (command === "load") {
    console.log(JSON.stringify(await loadNewsState()));
}
else if (command === "add") {
    await addShownNewsIds(rest);
    console.log(JSON.stringify(await loadNewsState()));
}
else if (command === "set-version") {
    await setLastShownUpdateVersion(rest[0]);
    console.log(JSON.stringify(await loadNewsState()));
}
else {
    throw new Error(`Unknown command: ${command}`);
}
