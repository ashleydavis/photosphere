import type { ReactNode } from "react";

//
// Category label for grouping stories in the browser list.
// Stories are rendered under headers in this fixed order:
// Pages, Modals, Dialogs, Components.
//
export type StoryCategory = "Pages" | "Modals" | "Dialogs" | "Components";

//
// A single registered story.
// Each story is a self-contained render function responsible for wrapping
// its content in any context providers it needs and supplying mock data
// and event handlers.
//
export interface IStory {
    //
    // Globally unique kebab-case slug used as URL query value and React list key.
    // Convention: `<component-name>/<variant>` (example: `"spinner/visible"`,
    // `"gallery-page/empty"`).
    //
    id: string;

    //
    // Short human-readable label shown in the list.
    //
    name: string;

    //
    // Group label shown as a header in the list. Must be one of:
    // "Pages", "Modals", "Dialogs", "Components".
    //
    category: StoryCategory;

    //
    // Function returning a React node for the story body. The function is
    // responsible for wrapping its content in any context providers it needs
    // and for supplying mock data and event handlers.
    //
    render: () => ReactNode;
}
