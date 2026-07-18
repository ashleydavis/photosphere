import { ZMachine } from "zmachine";
import { findGame, resolveGameId, ZORK_GAMES } from "./catalog";
import { loadStoryBuffer } from "./load-story";
import { TerminalIO } from "./terminal-io";

// Prints CLI usage help to stdout.
function printUsage(): void {
    console.log("Zork — TypeScript Z-machine player");
    console.log("");
    console.log("Usage:");
    console.log("  bun run play              Play Zork I (default)");
    console.log("  bun run play -- zork1     Play Zork I");
    console.log("  bun run play -- zork2     Play Zork II");
    console.log("  bun run play -- zork3     Play Zork III");
    console.log("  bun run play -- 1|2|3     Same as zork1/2/3");
    console.log("");
    console.log("Games:");

    for (const game of ZORK_GAMES) {
        console.log(`  ${game.id.padEnd(8)} ${game.title}: ${game.subtitle}`);
    }

    console.log("");
    console.log("In-game: type HELP, then explore. QUIT to exit.");
}

// Starts a Zork title in the terminal.
async function main(): Promise<void> {
    const args = process.argv.slice(2).filter(arg => arg !== "--");

    if (args.includes("-h") || args.includes("--help") || args.includes("help")) {
        printUsage();
        return;
    }

    const gameId = resolveGameId(args[0]);
    const game = findGame(gameId);

    if (game === undefined) {
        throw new Error(`Game not found: ${gameId}`);
    }

    const io = new TerminalIO(`.zork-${game.id}.sav`);
    const story = await loadStoryBuffer(game);
    const machine = ZMachine.load(story, io);

    console.log(`${game.title}: ${game.subtitle}`);
    console.log("TypeScript Z-machine  |  MIT-licensed Infocom source");
    console.log("");

    await machine.run();
    io.close();
}

main().catch((error: any) => {
    console.error(error.message || error);
    process.exit(1);
});
