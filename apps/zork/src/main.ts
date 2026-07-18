import { ZMachine, WebIOAdapter } from "zmachine";
import { findGame, resolveGameId, ZORK_GAMES, type ZorkGameId } from "./catalog";

// Browser bootstrapping for the shareable Zork web player.

// DOM handles for the two app screens.
interface IScreenElements {
    // Landing / title screen root.
    landing: HTMLElement;
    // Active game screen root.
    play: HTMLElement;
    // Status line element.
    status: HTMLElement;
    // Scrolling transcript element.
    output: HTMLElement;
    // Player command input.
    input: HTMLInputElement;
    // Title shown above the transcript.
    playTitle: HTMLElement;
}

// Wires the landing page and starts a game when a title is chosen.
async function boot(): Promise<void> {
    const screens = requireScreens();
    const params = new URLSearchParams(window.location.search);
    const requested = params.get("game");

    wireLanding(screens);

    if (requested !== null) {
        const gameId = resolveGameId(requested);
        await startGame(gameId, screens);
    }
}

// Collects required DOM nodes or throws when the page is incomplete.
function requireScreens(): IScreenElements {
    const landing = document.getElementById("landing");
    const play = document.getElementById("play");
    const status = document.getElementById("status");
    const output = document.getElementById("output");
    const input = document.getElementById("input");
    const playTitle = document.getElementById("play-title");

    if (
        landing === null ||
        play === null ||
        status === null ||
        output === null ||
        input === null ||
        playTitle === null ||
        !(input instanceof HTMLInputElement)
    ) {
        throw new Error("Zork page is missing required elements.");
    }

    return {
        landing: landing,
        play: play,
        status: status,
        output: output,
        input: input,
        playTitle: playTitle,
    };
}

// Binds click handlers on the landing game cards and restart control.
function wireLanding(screens: IScreenElements): void {
    const buttons = document.querySelectorAll<HTMLButtonElement>("[data-game]");

    for (const button of buttons) {
        button.addEventListener("click", () => {
            const gameId = button.dataset.game;

            if (gameId === undefined) {
                return;
            }

            void startGame(resolveGameId(gameId), screens);
        });
    }

    const back = document.getElementById("back-home");

    if (back !== null) {
        back.addEventListener("click", () => {
            window.location.href = "./";
        });
    }
}

// Loads a story file and runs it in the browser UI.
async function startGame(gameId: ZorkGameId, screens: IScreenElements): Promise<void> {
    const game = findGame(gameId);

    if (game === undefined) {
        throw new Error(`Unknown game: ${gameId}`);
    }

    screens.landing.hidden = true;
    screens.play.hidden = false;
    screens.playTitle.textContent = `${game.title}: ${game.subtitle}`;
    screens.output.replaceChildren();
    screens.status.textContent = game.title;
    screens.input.value = "";
    screens.input.focus();

    const url = new URL(window.location.href);
    url.searchParams.set("game", gameId);
    window.history.replaceState({}, "", url);

    const response = await fetch(game.storyPath);

    if (!response.ok) {
        screens.output.textContent = `Failed to load ${game.storyPath}`;
        return;
    }

    const storyData = await response.arrayBuffer();
    const io = new WebIOAdapter({
        outputElement: screens.output,
        inputElement: screens.input,
        statusElement: screens.status,
        onQuit: () => {
            screens.input.disabled = true;
            screens.input.placeholder = "Game over — choose another title from Home";
        },
        onRestart: () => {
            screens.output.replaceChildren();
            screens.input.disabled = false;
            screens.input.placeholder = "Enter a command";
            screens.input.focus();
        },
    });

    const machine = ZMachine.load(storyData, io);
    await machine.run();
}

// Expose catalog on window for smoke checks in tests/tools.
declare global {
    interface Window {
        // Bundled game list for debugging.
        __ZORK_GAMES__: typeof ZORK_GAMES;
    }
}

window.__ZORK_GAMES__ = ZORK_GAMES;

boot().catch((error: any) => {
    console.error(error);
    const output = document.getElementById("output");

    if (output !== null) {
        output.textContent = error.message || String(error);
    }
});
