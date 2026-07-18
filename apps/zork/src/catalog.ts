// Metadata for each bundled Zork trilogy title.

// Identifies which Zork game to launch.
export type ZorkGameId = "zork1" | "zork2" | "zork3";

// Display and asset info for one trilogy title.
export interface IZorkGameInfo {
    // Stable id used on the CLI and in URLs.
    id: ZorkGameId;
    // Short title shown in menus.
    title: string;
    // One-line pitch shown under the title.
    subtitle: string;
    // Relative path to the compiled Z-machine story file.
    storyPath: string;
    // Filename only, useful for filesystem lookups.
    storyFileName: string;
}

// The three MIT-licensed Zork titles shipped with this app.
export const ZORK_GAMES: IZorkGameInfo[] = [
    {
        id: "zork1",
        title: "Zork I",
        subtitle: "The Great Underground Empire",
        storyPath: "stories/zork1.z3",
        storyFileName: "zork1.z3",
    },
    {
        id: "zork2",
        title: "Zork II",
        subtitle: "The Wizard of Frobozz",
        storyPath: "stories/zork2.z3",
        storyFileName: "zork2.z3",
    },
    {
        id: "zork3",
        title: "Zork III",
        subtitle: "The Dungeon Master",
        storyPath: "stories/zork3.z3",
        storyFileName: "zork3.z3",
    },
];

// Looks up game metadata by id, or undefined when unknown.
export function findGame(gameId: string): IZorkGameInfo | undefined {
    return ZORK_GAMES.find(game => game.id === gameId);
}

// Parses CLI/URL game selectors such as "1", "zork1", or "Zork II".
export function resolveGameId(raw: string | undefined): ZorkGameId {
    if (raw === undefined || raw.trim().length === 0) {
        return "zork1";
    }

    const normalized = raw.trim().toLowerCase();

    if (normalized === "1" || normalized === "i" || normalized === "zork1" || normalized === "zork-1") {
        return "zork1";
    }

    if (normalized === "2" || normalized === "ii" || normalized === "zork2" || normalized === "zork-2") {
        return "zork2";
    }

    if (normalized === "3" || normalized === "iii" || normalized === "zork3" || normalized === "zork-3") {
        return "zork3";
    }

    const match = findGame(normalized);

    if (match !== undefined) {
        return match.id;
    }

    throw new Error(
        `Unknown game "${raw}". Use zork1, zork2, or zork3.`
    );
}
