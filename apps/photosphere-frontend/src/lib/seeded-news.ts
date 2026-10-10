import type { IShowNotificationData, ISeedNewsItem } from "user-interface";

//
// Maps the news items a test seeds to the toast the first of them shows, or undefined when none were seeded. The colour defaults
// to "primary" and the toast stays until dismissed, as a news item that sets neither does. The newsId lets dismissing the toast
// record the item as shown.
//
export function firstSeededNewsNotification(items: ISeedNewsItem[]): IShowNotificationData | undefined {
    if (items.length === 0) {
        return undefined;
    }
    const item = items[0];
    return {
        message: item.message,
        color: toastColor(item.color),
        duration: 0,
        newsId: item.id,
    };
}

//
// The toast colour for a seeded item's colour, "primary" when it names none. A colour that is not a toast colour throws.
//
function toastColor(color: string | undefined): IShowNotificationData["color"] {
    if (color === undefined) {
        return "primary";
    }
    if (color === "primary" || color === "success" || color === "warning" || color === "danger" || color === "neutral") {
        return color;
    }
    throw new Error(`The seeded news colour "${color}" is not one of primary, success, warning, danger or neutral.`);
}
