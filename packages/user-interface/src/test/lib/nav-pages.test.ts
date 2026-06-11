import { findTemporaryNavPage, navPages } from "../../lib/nav-pages";

//
// The pages the navbar links permanently.
//
const NAVBAR_PERMANENT = ["/gallery", "/map", "/import"];

//
// The pages the sidebar links permanently.
//
const SIDEBAR_PERMANENT = ["/gallery", "/map", "/import", "/databases", "/secrets"];

describe("findTemporaryNavPage", () => {

    test("matches a known page by exact path", () => {
        expect(findTemporaryNavPage("/about", NAVBAR_PERMANENT)?.label).toBe("About");
        expect(findTemporaryNavPage("/news", NAVBAR_PERMANENT)?.label).toBe("News");
        expect(findTemporaryNavPage("/database-summary", NAVBAR_PERMANENT)?.label).toBe("Database Info");
    });

    test("matches a page with a trailing sub-path", () => {
        expect(findTemporaryNavPage("/about/details", NAVBAR_PERMANENT)?.path).toBe("/about");
    });

    test("navbar shows a temporary entry for sidebar-only pages", () => {
        expect(findTemporaryNavPage("/databases", NAVBAR_PERMANENT)?.label).toBe("Manage Databases");
        expect(findTemporaryNavPage("/secrets", NAVBAR_PERMANENT)?.label).toBe("Manage Secrets");
    });

    test("sidebar does not show a temporary entry for its own permanent pages", () => {
        expect(findTemporaryNavPage("/databases", SIDEBAR_PERMANENT)).toBeUndefined();
        expect(findTemporaryNavPage("/secrets", SIDEBAR_PERMANENT)).toBeUndefined();
    });

    test("returns undefined for a bar's own permanent pages", () => {
        expect(findTemporaryNavPage("/gallery", NAVBAR_PERMANENT)).toBeUndefined();
        expect(findTemporaryNavPage("/map", NAVBAR_PERMANENT)).toBeUndefined();
        expect(findTemporaryNavPage("/import", NAVBAR_PERMANENT)).toBeUndefined();
    });

    test("returns undefined for an unknown path", () => {
        expect(findTemporaryNavPage("/does-not-exist", NAVBAR_PERMANENT)).toBeUndefined();
    });

    test("does not match a path that merely starts with a page name but is not a sub-path", () => {
        expect(findTemporaryNavPage("/aboutness", NAVBAR_PERMANENT)).toBeUndefined();
    });

    test("every page has a label and icon", () => {
        for (const navPage of navPages) {
            expect(navPage.label.length).toBeGreaterThan(0);
            expect(navPage.icon).toBeTruthy();
        }
    });
});
