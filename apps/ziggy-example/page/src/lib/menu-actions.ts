//
// What the page does for each action of the example's menu that the shells hand it. The shells do the rest themselves
// (quit, reload, developer tools, zoom, full screen and the editing commands).
//

//
// The data-id of the button an action presses, so the menu and the buttons do exactly the same thing.
//
const buttonForAction: { [action: string]: string } = {
    "start-short": "start-short",
    "start-long": "start-long",
    "start-many": "start-many",
    "cancel-long": "cancel-source",
};

//
// The text the About item shows.
//
export const aboutText = "Ziggy example: a small app built on Ziggy.";

//
// The data-id of the button an action presses, or null when the action does not press one.
//
export function buttonForMenuAction(action: string): string | null {
    return buttonForAction[action] ?? null;
}
