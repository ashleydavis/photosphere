import type { ElementType } from "react";
import Info from "@mui/icons-material/Info";
import Newspaper from "@mui/icons-material/Newspaper";
import Storage from "@mui/icons-material/Storage";
import ManageSearch from "@mui/icons-material/ManageSearch";
import Key from "@mui/icons-material/Key";

//
// Describes a page that may need a temporary entry in the navbar or sidebar.
// A page gets a temporary entry in a given bar when the user is on it but that
// bar has no permanent link for it, so the user can still see where they are.
//
export interface INavPage {
    //
    // The route path this entry matches (e.g. "/about").
    //
    path: string;

    //
    // The human-readable label shown for the temporary nav entry.
    //
    label: string;

    //
    // The icon component shown beside the label.
    //
    icon: ElementType;
}

//
// Pages that at least one of the navbar or sidebar does not link permanently.
// Pages linked permanently in both bars (gallery, map, import) are omitted
// because they never need a temporary entry.
//
export const navPages: INavPage[] = [
    {
        path: "/databases",
        label: "Manage Databases",
        icon: ManageSearch,
    },
    {
        path: "/secrets",
        label: "Manage Secrets",
        icon: Key,
    },
    {
        path: "/about",
        label: "About",
        icon: Info,
    },
    {
        path: "/news",
        label: "News",
        icon: Newspaper,
    },
    {
        path: "/database-summary",
        label: "Database Info",
        icon: Storage,
    },
];

//
// Finds the page (if any) that should be shown as a temporary entry for the
// given location pathname. Returns undefined when the location is unknown or
// already has a permanent entry in this bar (so no temporary entry is needed).
//
export function findTemporaryNavPage(pathname: string, permanentPaths: string[]): INavPage | undefined {
    const matchedPage = navPages.find(navPage => pathname === navPage.path || pathname.startsWith(navPage.path + "/"));
    if (!matchedPage) {
        return undefined;
    }

    if (permanentPaths.includes(matchedPage.path)) {
        return undefined;
    }

    return matchedPage;
}
