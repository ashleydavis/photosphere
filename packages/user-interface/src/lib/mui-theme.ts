import { createTheme, type Theme } from "@mui/material/styles";

//
// The MUI theme every page is drawn in. It has a light and a dark colour scheme, and MUI marks
// the page with the class of the scheme in use, `light` or `dark`, on the `<html>` element.
//
export const photosphereTheme: Theme = createTheme({
    cssVariables: {
        colorSchemeSelector: "class",
    },
    colorSchemes: {
        light: true,
        dark: true,
    },
    components: {
        MuiMenu: {
            defaultProps: {
                slotProps: {
                    //
                    // A menu goes the moment it closes, with no fade out, so the items of a menu that
                    // has just closed are never on screen beside those of the next menu opened.
                    //
                    transition: {
                        exit: false,
                    },
                },
            },
        },
        MuiButton: {
            styleOverrides: {
                //
                // Button labels keep the case they are written in.
                //
                root: {
                    textTransform: "none",
                },
            },
        },
    },
});
