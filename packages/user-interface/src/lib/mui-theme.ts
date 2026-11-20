//
// Builds the MUI theme for the app. Every colour, size and radius in it is a CSS variable
// from photosphere.css, so a component follows the light or dark class of the panel it sits in
// and picks up edits to photosphere.css while the page stays open.
//

import { createTheme, type Theme } from "@mui/material/styles";

//
// Adds a "dialog" variant to MUI's Paper, so every dialog draws its surface from one style.
//
declare module "@mui/material/Paper" {
    interface PaperPropsVariantOverrides {
        dialog: true;
    }
}

//
// The ring drawn around a control the keyboard is on, from the focus tokens.
//
const FOCUS_RING = {
    outline: "var(--focus-ring-width) solid var(--color-focus)",
    outlineOffset: "var(--focus-ring-offset)",
};

//
// The MUI theme every page of the app is drawn in. Styles go in styleOverrides instead of the
// palette, because MUI works out hover and contrast colours by parsing palette values, and that
// parsing accepts only literal colours.
//
export const photosphereTheme: Theme = createTheme({
    //
    // MUI marks the page with the class of the scheme in use, `light` or `dark`, on the `<html>`
    // element, which is the class photosphere.css switches its role tokens on.
    //
    cssVariables: {
        colorSchemeSelector: "class",
    },
    colorSchemes: {
        light: true,
        dark: true,
    },
    typography: {
        fontFamily: "var(--font-sans)",
    },
    components: {
        MuiButton: {
            defaultProps: {
                disableElevation: true,
            },
            styleOverrides: {
                root: {
                    textTransform: "none",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    fontWeight: "var(--weight-medium)",
                    lineHeight: "var(--leading-tight)",
                    borderRadius: "var(--radius-button)",
                    transition: "background-color var(--duration-fast) var(--ease-standard)",
                    "&:focus-visible": FOCUS_RING,
                    //
                    // A danger button, such as Delete, takes its fill, text and border from the
                    // danger button tokens whatever its variant, and its border thickens under
                    // the pointer.
                    //
                    "&.MuiButton-colorError": {
                        backgroundColor: "var(--color-danger-button-fill)",
                        color: "var(--color-danger-button-text)",
                        border: "1px solid var(--color-danger-button-border)",
                    },
                    "&.MuiButton-colorError:hover": {
                        backgroundColor: "var(--color-danger-button-fill)",
                        boxShadow: "inset 0 0 0 1px var(--color-danger-button-border)",
                    },
                },
                startIcon: {
                    "& > *:nth-of-type(1)": {
                        fontSize: "var(--icon-md)",
                    },
                },
                sizeSmall: {
                    fontSize: "var(--text-sm)",
                    padding: "var(--space-1) var(--space-2)",
                    minHeight: "var(--button-height-sm)",
                },
                sizeMedium: {
                    padding: "var(--space-2) var(--space-4)",
                    minHeight: "var(--button-height-md)",
                },
                sizeLarge: {
                    fontSize: "var(--text-lg)",
                    padding: "var(--space-3) var(--space-6)",
                    minHeight: "var(--button-height-lg)",
                },
                //
                // Every button has a visible border, as the UX rules ask. Contained and text
                // buttons draw theirs as a 1px line inside the button, so it adds no size and
                // every kind of button stays the same height.
                //
                contained: {
                    backgroundColor: "var(--color-accent)",
                    color: "var(--color-on-accent)",
                    boxShadow: "inset 0 0 0 1px var(--color-accent-hover), var(--shadow-button-main)",
                    "&:hover": {
                        backgroundColor: "var(--color-accent-hover)",
                        boxShadow: "inset 0 0 0 1px var(--color-accent-hover), var(--shadow-button-main)",
                    },
                    "&.Mui-disabled": {
                        backgroundColor: "var(--color-disabled)",
                        color: "var(--color-text-disabled)",
                        boxShadow: "inset 0 0 0 1px var(--color-border)",
                    },
                },
                outlined: {
                    borderColor: "var(--color-border-control)",
                    color: "var(--color-text)",
                    "&:hover": {
                        borderColor: "var(--color-border-control)",
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-disabled": {
                        borderColor: "var(--color-border)",
                        color: "var(--color-text-disabled)",
                    },
                },
                text: {
                    color: "var(--color-text)",
                    boxShadow: "inset 0 0 0 1px var(--color-border)",
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                        boxShadow: "inset 0 0 0 1px var(--color-border)",
                    },
                },
            },
        },
        MuiOutlinedInput: {
            styleOverrides: {
                root: {
                    backgroundColor: "var(--color-input)",
                    color: "var(--color-text)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    borderRadius: "var(--radius-md)",
                    "& .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-border-control)",
                    },
                    "&:hover .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-text-muted)",
                    },
                    "&.Mui-focused .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-focus)",
                    },
                    "&.Mui-focused": {
                        boxShadow: "var(--focus-glow)",
                    },
                    //
                    // A search box, such as the gallery's, takes the search tokens for its fill, its
                    // border and its corners, apart from other text boxes.
                    //
                    "&.photosphere-search": {
                        backgroundColor: "var(--color-search-bg)",
                        borderRadius: "var(--radius-search)",
                    },
                    "&.photosphere-search .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-search-border)",
                    },
                    //
                    // The search box's clear button is small enough to keep --space-2 or more between it
                    // and the box's edge on every side, as the UX rules on spacing ask.
                    //
                    "&.photosphere-search .MuiIconButton-root": {
                        width: "var(--search-clear-size)",
                        height: "var(--search-clear-size)",
                        fontSize: "var(--icon-sm)",
                    },
                    "&.Mui-error .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-danger)",
                    },
                    "&.Mui-disabled": {
                        backgroundColor: "var(--color-disabled)",
                    },
                    "&.Mui-disabled .MuiOutlinedInput-notchedOutline": {
                        borderColor: "var(--color-border)",
                    },
                },
                input: {
                    "&::placeholder": {
                        color: "var(--color-text-muted)",
                        opacity: 1,
                    },
                    "&.Mui-disabled": {
                        WebkitTextFillColor: "var(--color-text-disabled)",
                    },
                },
            },
        },
        MuiInputLabel: {
            styleOverrides: {
                root: {
                    color: "var(--color-text-muted)",
                    fontSize: "var(--text-md)",
                    "&.Mui-focused": {
                        color: "var(--color-focus)",
                    },
                    "&.Mui-error": {
                        color: "var(--color-danger)",
                    },
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                    },
                },
            },
        },
        MuiFormHelperText: {
            styleOverrides: {
                root: {
                    color: "var(--color-text-muted)",
                    fontSize: "var(--text-sm)",
                    "&.Mui-error": {
                        color: "var(--color-danger)",
                    },
                },
            },
        },
        MuiInputAdornment: {
            styleOverrides: {
                root: {
                    color: "var(--color-text-muted)",
                    fontSize: "var(--icon-md)",
                },
            },
        },
        MuiIconButton: {
            styleOverrides: {
                //
                // An icon button is square, the height of a button of its size, with the icon
                // centred and room on every side between it and the border, as the UX rules ask.
                //
                root: {
                    width: "var(--button-height-md)",
                    height: "var(--button-height-md)",
                    padding: 0,
                    flex: "none",
                    fontSize: "var(--icon-lg)",
                    color: "var(--color-text-muted)",
                    borderRadius: "var(--radius-icon-button)",
                    backgroundColor: "var(--color-icon-button-fill)",
                    border: "1px solid var(--color-icon-button-border)",
                    //
                    // An icon button in the gallery's selection bar takes the bar's text colour, with
                    // its border in that colour faded, so it reads on any bar surface.
                    //
                    "&.photosphere-bar-button": {
                        color: "inherit",
                        borderColor: "color-mix(in srgb, currentColor 40%, transparent)",
                    },
                    //
                    // A control of the photo viewer takes the viewer control tokens, so it reads over
                    // any photo: its fill, edge, text colour, corners and how much it blurs the photo
                    // behind it.
                    //
                    "&.photosphere-viewer-button": {
                        color: "var(--color-viewer-control-text)",
                        backgroundColor: "var(--color-viewer-control-fill)",
                        borderColor: "var(--color-viewer-control-border)",
                        borderRadius: "var(--radius-viewer-control)",
                        backdropFilter: "blur(var(--viewer-control-blur))",
                    },
                    //
                    // A dangerous button in the selection bar or the viewer, such as Delete, takes the
                    // danger colour for its icon and border, as the UX rules ask; the viewer has a
                    // danger colour of its own that reads on its dark background.
                    //
                    "&.photosphere-bar-button.photosphere-danger": {
                        color: "var(--color-danger)",
                        borderColor: "var(--color-danger)",
                    },
                    "&.photosphere-viewer-button.photosphere-danger": {
                        color: "var(--color-viewer-danger)",
                        borderColor: "var(--color-viewer-danger)",
                    },
                    "&.photosphere-viewer-button:hover": {
                        color: "var(--color-viewer-control-text)",
                        backgroundColor: "color-mix(in srgb, var(--color-viewer-control-text) 20%, var(--color-viewer-control-fill))",
                    },
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                        color: "var(--color-text)",
                    },
                    "&:focus-visible": FOCUS_RING,
                    //
                    // A disabled icon button takes the disabled colours of every other disabled
                    // button, a dangerous one in the selection bar included, as the UX rules ask.
                    //
                    "&.Mui-disabled, &.photosphere-bar-button.photosphere-danger.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                        borderColor: "var(--color-border)",
                    },
                },
                sizeSmall: {
                    width: "var(--button-height-sm)",
                    height: "var(--button-height-sm)",
                    fontSize: "var(--icon-md)",
                },
            },
        },
        MuiLink: {
            styleOverrides: {
                root: {
                    color: "var(--color-text)",
                    textDecorationColor: "var(--color-text-muted)",
                },
            },
        },
        MuiToggleButton: {
            styleOverrides: {
                root: {
                    textTransform: "none",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    color: "var(--color-text-muted)",
                    borderColor: "var(--color-border)",
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-selected": {
                        backgroundColor: "var(--color-accent)",
                        color: "var(--color-on-accent)",
                    },
                    "&.Mui-selected:hover": {
                        backgroundColor: "var(--color-accent-hover)",
                    },
                    "&:focus-visible": FOCUS_RING,
                },
            },
        },
        MuiToggleButtonGroup: {
            styleOverrides: {
                root: {
                    borderRadius: "var(--radius-md)",
                },
            },
        },
        MuiDrawer: {
            styleOverrides: {
                paper: {
                    backgroundColor: "var(--color-panel)",
                    backgroundImage: "none",
                    color: "var(--color-text)",
                    borderRight: "1px solid var(--color-border)",
                    boxShadow: "var(--shadow-overlay)",
                },
            },
        },
        MuiPopover: {
            defaultProps: {
                //
                // The page keeps its scrollbar while a popover is open, so the page does not
                // jump as it opens and closes.
                //
                disableScrollLock: true,
            },
            styleOverrides: {
                paper: {
                    backgroundColor: "var(--color-panel)",
                    backgroundImage: "none",
                    color: "var(--color-text)",
                    border: "1px solid var(--color-border)",
                    borderRadius: "var(--radius-md)",
                    boxShadow: "var(--shadow-overlay)",
                },
            },
        },
        MuiPaper: {
            variants: [
                {
                    props: {
                        variant: "dialog",
                    },
                    style: {
                        backgroundColor: "var(--color-panel)",
                        backgroundImage: "none",
                        color: "var(--color-text)",
                        border: "1px solid var(--color-border)",
                        borderRadius: "var(--radius-lg)",
                        boxShadow: "var(--shadow-overlay)",
                    },
                },
            ],
        },
        MuiDialog: {
            defaultProps: {
                slotProps: {
                    paper: {
                        variant: "dialog",
                    },
                },
            },
        },
        MuiBackdrop: {
            styleOverrides: {
                root: {
                    backgroundColor: "var(--color-scrim)",
                    backdropFilter: "blur(var(--backdrop-blur))",
                },
                invisible: {
                    backgroundColor: "transparent",
                },
            },
        },
        MuiDialogTitle: {
            styleOverrides: {
                root: {
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-lg)",
                    fontWeight: "var(--weight-bold)",
                    padding: "var(--space-4) var(--space-6) var(--space-2)",
                },
            },
        },
        MuiDialogContent: {
            styleOverrides: {
                root: {
                    padding: "var(--space-2) var(--space-6) var(--space-4)",
                },
            },
        },
        MuiDialogActions: {
            //
            // The space between the buttons comes from the gap below, so MUI's own margin
            // between them is off.
            //
            defaultProps: {
                disableSpacing: true,
            },
            styleOverrides: {
                root: {
                    padding: "var(--space-2) var(--space-6) var(--space-4)",
                    gap: "var(--space-2)",
                },
            },
        },
        MuiMenu: {
            defaultProps: {
                slotProps: {
                    //
                    // A menu goes the moment it closes, with no fade out, so the items of a menu
                    // that has just closed are never on screen beside those of the next menu opened.
                    //
                    transition: {
                        exit: false,
                    },
                },
            },
            styleOverrides: {
                list: {
                    padding: "var(--space-1)",
                },
            },
        },
        MuiAutocomplete: {
            styleOverrides: {
                //
                // The suggestions take the look of a menu: the panel fill and border, and rows
                // that show the hover and selected colours.
                //
                paper: {
                    backgroundColor: "var(--color-panel)",
                    backgroundImage: "none",
                    color: "var(--color-text)",
                    border: "1px solid var(--color-border)",
                    borderRadius: "var(--radius-md)",
                    boxShadow: "var(--shadow-overlay)",
                },
                listbox: {
                    padding: "var(--space-1)",
                    "& .MuiAutocomplete-option": {
                        gap: "var(--space-3)",
                        minHeight: "var(--menu-item-height)",
                        padding: "var(--space-1) var(--space-3)",
                        borderRadius: "var(--radius-sm)",
                        color: "var(--color-text)",
                    },
                    "& .MuiAutocomplete-option.Mui-focused": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "& .MuiAutocomplete-option[aria-selected='true'], & .MuiAutocomplete-option[aria-selected='true'].Mui-focused": {
                        backgroundColor: "var(--color-selected)",
                    },
                },
                noOptions: {
                    color: "var(--color-text-muted)",
                },
            },
        },
        MuiMenuItem: {
            styleOverrides: {
                root: {
                    //
                    // MUI sets its own minimum height above its small screen size, so the height
                    // goes on a selector with two classes, which wins over that rule.
                    //
                    "&.MuiMenuItem-root": {
                        minHeight: "var(--menu-item-height)",
                    },
                    gap: "var(--space-2)",
                    padding: "0 var(--space-3)",
                    borderRadius: "var(--radius-sm)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    color: "var(--color-text)",
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    //
                    // A selected item takes the selected fill and a 1px edge, which marks it at
                    // 3 to 1 against the panel where the fill alone is too faint.
                    //
                    "&.Mui-selected, &.Mui-selected:hover": {
                        backgroundColor: "var(--color-selected)",
                        boxShadow: "inset 0 0 0 1px var(--color-selected-edge)",
                    },
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                        opacity: 1,
                    },
                    "&.Mui-focusVisible": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "& .svg-inline--fa": {
                        fontSize: "var(--icon-md)",
                        width: "var(--icon-md)",
                        color: "var(--color-text-muted)",
                    },
                },
            },
        },
        MuiDivider: {
            styleOverrides: {
                root: {
                    borderColor: "var(--color-border)",
                },
            },
        },
        MuiTooltip: {
            defaultProps: {
                arrow: true,
            },
            styleOverrides: {
                tooltip: {
                    backgroundColor: "var(--color-tooltip-bg)",
                    color: "var(--color-tooltip-text)",
                    border: "1px solid var(--color-tooltip-border)",
                    boxShadow: "var(--shadow-tooltip)",
                    borderRadius: "var(--radius-sm)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-sm)",
                    fontWeight: "var(--weight-normal)",
                    padding: "var(--space-1) var(--space-2)",
                },
                arrow: {
                    color: "var(--color-tooltip-bg)",
                    "&::before": {
                        border: "1px solid var(--color-tooltip-border)",
                    },
                },
            },
        },
        MuiCheckbox: {
            styleOverrides: {
                root: {
                    color: "var(--color-border-control)",
                    //
                    // Under the pointer the toggle takes the hover fill round it, and from the
                    // keyboard the focus ring, as every other control does.
                    //
                    "&:hover, &.Mui-checked:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-focusVisible": FOCUS_RING,
                    "&.Mui-checked, &.MuiCheckbox-indeterminate": {
                        color: "var(--color-accent)",
                    },
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                    },
                },
            },
        },
        MuiRadio: {
            styleOverrides: {
                root: {
                    color: "var(--color-border-control)",
                    //
                    // Under the pointer the toggle takes the hover fill round it, and from the
                    // keyboard the focus ring, as every other control does.
                    //
                    "&:hover, &.Mui-checked:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-focusVisible": FOCUS_RING,
                    "&.Mui-checked": {
                        color: "var(--color-accent)",
                    },
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                    },
                },
            },
        },
        MuiSwitch: {
            //
            // The switch's size comes from the switch tokens: a rounded track with the knob
            // centred on it, travelling the track's width less its height when switched on.
            //
            styleOverrides: {
                root: {
                    width: "var(--switch-track-width)",
                    height: "var(--switch-track-height)",
                    padding: 0,
                    overflow: "visible",
                    margin: "0 var(--space-2)",
                    //
                    // Under the pointer the track takes the hover fill round it, and from the
                    // keyboard the focus ring, as every other control does.
                    //
                    "&:hover .MuiSwitch-track": {
                        boxShadow: "0 0 0 var(--space-1) var(--color-hover)",
                    },
                    "& .Mui-focusVisible + .MuiSwitch-track": FOCUS_RING,
                },
                switchBase: {
                    padding: "calc((var(--switch-track-height) - var(--switch-thumb-size)) / 2)",
                    color: "var(--color-panel)",
                    "&:hover, &.Mui-checked:hover": {
                        backgroundColor: "transparent",
                    },
                    "&.Mui-checked": {
                        transform: "translateX(calc(var(--switch-track-width) - var(--switch-track-height)))",
                        color: "var(--color-on-accent)",
                    },
                    "&.Mui-checked + .MuiSwitch-track": {
                        backgroundColor: "var(--color-accent)",
                        opacity: 1,
                    },
                    "&.Mui-disabled + .MuiSwitch-track": {
                        backgroundColor: "var(--color-disabled)",
                        opacity: 1,
                    },
                    "&.Mui-disabled .MuiSwitch-thumb": {
                        color: "var(--color-text-disabled)",
                    },
                },
                thumb: {
                    width: "var(--switch-thumb-size)",
                    height: "var(--switch-thumb-size)",
                    boxShadow: "var(--shadow-raised)",
                },
                track: {
                    borderRadius: "var(--radius-full)",
                    backgroundColor: "var(--color-border-control)",
                    opacity: 1,
                },
            },
        },
        MuiFormControlLabel: {
            styleOverrides: {
                //
                // Every toggle row is 44px or taller, a touch target, so rows of switches,
                // checkboxes and radio buttons line up.
                //
                root: {
                    minHeight: "calc(var(--space-8) + var(--space-3))",
                },
                label: {
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    color: "var(--color-text)",
                    "&.Mui-disabled": {
                        color: "var(--color-text-disabled)",
                    },
                },
            },
        },
        MuiAlert: {
            //
            // A banner takes its status colour for its icon, its tint, its border and its bar
            // down the left edge. The banner tokens set how strong each one is. The status rules
            // sit under root, so they win over MUI's own colours for each status.
            //
            styleOverrides: {
                root: {
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    borderRadius: "var(--radius-md)",
                    borderStyle: "solid",
                    borderWidth: "var(--banner-border-width)",
                    borderLeftWidth: "max(var(--banner-border-width), var(--banner-bar-width))",
                    "&.MuiAlert-colorInfo": {
                        color: "var(--color-text)",
                        backgroundColor: "color-mix(in srgb, var(--color-info) var(--banner-tint), var(--color-panel))",
                        borderColor: "var(--color-info)",
                    },
                    "&.MuiAlert-colorInfo .MuiAlert-icon": {
                        color: "var(--color-info)",
                    },
                    "&.MuiAlert-colorSuccess": {
                        color: "var(--color-text)",
                        backgroundColor: "color-mix(in srgb, var(--color-success) var(--banner-tint), var(--color-panel))",
                        borderColor: "var(--color-success)",
                    },
                    "&.MuiAlert-colorSuccess .MuiAlert-icon": {
                        color: "var(--color-success)",
                    },
                    "&.MuiAlert-colorWarning": {
                        color: "var(--color-text)",
                        backgroundColor: "color-mix(in srgb, var(--color-warning) var(--banner-tint), var(--color-panel))",
                        borderColor: "var(--color-warning)",
                    },
                    "&.MuiAlert-colorWarning .MuiAlert-icon": {
                        color: "var(--color-warning)",
                    },
                    "&.MuiAlert-colorError": {
                        color: "var(--color-text)",
                        backgroundColor: "color-mix(in srgb, var(--color-danger) var(--banner-tint), var(--color-panel))",
                        borderColor: "var(--color-danger)",
                    },
                    "&.MuiAlert-colorError .MuiAlert-icon": {
                        color: "var(--color-danger)",
                    },
                },
                icon: {
                    fontSize: "var(--icon-lg)",
                },
            },
        },
        MuiAlertTitle: {
            styleOverrides: {
                root: {
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    fontWeight: "var(--weight-bold)",
                    marginBottom: "var(--space-1)",
                },
            },
        },
        MuiSelect: {
            styleOverrides: {
                icon: {
                    color: "var(--color-text-muted)",
                },
            },
        },
        MuiTabs: {
            //
            // The row of tabs. The selected tab is marked by the indicator under it, its own
            // background or both, as the tab tokens set.
            //
            styleOverrides: {
                root: {
                    minHeight: "var(--menu-item-height)",
                },
                list: {
                    gap: "var(--space-1)",
                },
                indicator: {
                    height: "var(--tab-indicator-height)",
                    backgroundColor: "var(--color-accent)",
                },
            },
        },
        MuiTab: {
            styleOverrides: {
                root: {
                    minHeight: "var(--menu-item-height)",
                    minWidth: 0,
                    padding: "0 var(--space-4)",
                    textTransform: "none",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    fontWeight: "var(--weight-medium)",
                    color: "var(--color-text-muted)",
                    borderRadius: "var(--radius-tab)",
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-selected": {
                        color: "var(--color-tab-selected-text)",
                        backgroundColor: "var(--color-tab-selected-bg)",
                    },
                    "&:focus-visible": FOCUS_RING,
                },
            },
        },
        MuiListItemButton: {
            //
            // A row of a list or the sidebar. The current row takes the navigation tokens: its
            // background, its text and a bar down its left edge in the accent.
            //
            styleOverrides: {
                root: {
                    minHeight: "var(--menu-item-height)",
                    gap: "var(--space-3)",
                    padding: "0 var(--space-3)",
                    borderRadius: "var(--radius-sm)",
                    color: "var(--color-text)",
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                    "&.Mui-selected, &.Mui-selected:hover": {
                        backgroundColor: "var(--color-nav-current-bg)",
                        color: "var(--color-nav-current-text)",
                        boxShadow: "inset var(--nav-current-bar-width) 0 0 var(--color-accent)",
                    },
                    "&.Mui-selected .svg-inline--fa": {
                        color: "var(--color-nav-current-text)",
                    },
                    "& .svg-inline--fa": {
                        fontSize: "var(--icon-md)",
                        width: "var(--icon-md)",
                        color: "var(--color-text-muted)",
                    },
                    "&:focus-visible": FOCUS_RING,
                },
            },
        },
        MuiListItemText: {
            styleOverrides: {
                primary: {
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                },
            },
        },
        MuiToolbar: {
            //
            // The bar across the top of a page, with the toolbar tokens for its surface, its edge,
            // its shadow and how much it blurs what scrolls under it.
            //
            styleOverrides: {
                root: {
                    gap: "var(--space-2)",
                    minHeight: "calc(var(--button-height-md) + var(--space-4))",
                    padding: "var(--space-2) var(--space-4)",
                    backgroundColor: "var(--color-toolbar-bg)",
                    borderBottom: "1px solid var(--color-toolbar-border)",
                    boxShadow: "var(--shadow-toolbar)",
                    backdropFilter: "blur(var(--toolbar-blur))",
                    //
                    // On a narrow screen the toolbar wraps onto a second line rather than squeeze
                    // its search box to nothing.
                    //
                    flexWrap: "wrap",
                    "@media (min-width: 600px)": {
                        minHeight: "calc(var(--button-height-md) + var(--space-4))",
                        padding: "var(--space-2) var(--space-4)",
                    },
                },
            },
        },
        MuiLinearProgress: {
            styleOverrides: {
                root: {
                    height: "var(--progress-height)",
                    borderRadius: "var(--radius-progress)",
                    backgroundColor: "var(--color-progress-track)",
                },
                bar: {
                    background: "var(--progress-fill)",
                    borderRadius: "var(--radius-progress)",
                },
            },
        },
        MuiCircularProgress: {
            styleOverrides: {
                root: {
                    color: "var(--color-accent)",
                },
            },
        },
        MuiChip: {
            //
            // A chip, such as an album or a person on a photo, takes the chip tokens for its
            // fill, border, text and corners.
            //
            styleOverrides: {
                root: {
                    height: "auto",
                    minHeight: "var(--button-height-sm)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-sm)",
                    backgroundColor: "var(--color-chip-bg)",
                    color: "var(--color-chip-text)",
                    border: "1px solid var(--color-chip-border)",
                    borderRadius: "var(--radius-chip)",
                    "& .svg-inline--fa": {
                        fontSize: "var(--icon-sm)",
                        color: "var(--color-chip-text)",
                        marginLeft: "var(--space-2)",
                    },
                },
                label: {
                    padding: "0 var(--space-3)",
                },
                deleteIcon: {
                    marginRight: "var(--space-2)",
                    color: "var(--color-chip-text)",
                    "&:hover": {
                        color: "var(--color-text)",
                    },
                },
                clickable: {
                    "&:hover": {
                        backgroundColor: "var(--color-hover)",
                    },
                },
            },
        },
        MuiSnackbarContent: {
            //
            // A toast takes the toast tokens for its surface, text and edge, the overlay shadow,
            // and the toast action colour for its button, such as Undo.
            //
            styleOverrides: {
                root: {
                    backgroundColor: "var(--color-toast-bg)",
                    color: "var(--color-toast-text)",
                    border: "1px solid var(--color-toast-border)",
                    borderRadius: "var(--radius-md)",
                    boxShadow: "var(--shadow-overlay)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-md)",
                    padding: "var(--space-1) calc(var(--space-4) + var(--toast-close-room)) var(--space-1) var(--space-4)",
                    gap: "var(--space-2)",
                    position: "relative",
                    //
                    // The close button takes the close button tokens: where it sits, inline at the
                    // toast's end or held in a corner, its size, shape, edge, fill and shadow, and
                    // its colour, by default the colour of the toast's text.
                    //
                    "& .MuiIconButton-root.photosphere-toast-close": {
                        position: "var(--toast-close-position)",
                        top: "var(--toast-close-top)",
                        right: "var(--toast-close-right)",
                        width: "var(--toast-close-size)",
                        height: "var(--toast-close-size)",
                        fontSize: "var(--icon-md)",
                        color: "var(--toast-close-color)",
                        opacity: "var(--toast-close-opacity)",
                        border: "var(--toast-close-border-width) solid color-mix(in srgb, currentColor 40%, transparent)",
                        borderRadius: "var(--toast-close-radius)",
                        backgroundColor: "var(--toast-close-fill)",
                        boxShadow: "var(--shadow-toast-close)",
                    },
                    //
                    // The cross is a square icon half the button's size, so it sits clear of the
                    // button's edge with the same room on every side. Font Awesome sets an icon's
                    // width in its own CSS, outside the theme's layers, so the width is set through
                    // its --fa-width variable.
                    //
                    "& .MuiIconButton-root.photosphere-toast-close .svg-inline--fa": {
                        fontSize: "calc(var(--toast-close-size) / 2)",
                        "--fa-width": "1em",
                    },
                    "& .MuiIconButton-root.photosphere-toast-close:hover": {
                        opacity: 1,
                        backgroundColor: "color-mix(in srgb, currentColor 14%, var(--toast-close-fill))",
                    },
                    //
                    // A status toast takes its status's toast colour: as a tint mixed into the
                    // surface, as a bar down its left edge and in its icon, each as strong as the
                    // status toast tokens set, with its text in the status text colour.
                    //
                    "&.photosphere-toast-info": {
                        backgroundColor: "color-mix(in srgb, var(--color-toast-info) var(--toast-status-tint), var(--color-toast-bg))",
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset var(--toast-status-bar-width) 0 0 var(--color-toast-info), var(--shadow-overlay)",
                    },
                    "&.photosphere-toast-info .photosphere-toast-icon": {
                        color: "color-mix(in srgb, var(--color-toast-info) var(--toast-status-icon-mix), var(--color-toast-status-text))",
                    },
                    "&.photosphere-toast-info .MuiButton-root": {
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset 0 0 0 1px var(--color-toast-status-text)",
                    },
                    "&.photosphere-toast-success": {
                        backgroundColor: "color-mix(in srgb, var(--color-toast-success) var(--toast-status-tint), var(--color-toast-bg))",
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset var(--toast-status-bar-width) 0 0 var(--color-toast-success), var(--shadow-overlay)",
                    },
                    "&.photosphere-toast-success .photosphere-toast-icon": {
                        color: "color-mix(in srgb, var(--color-toast-success) var(--toast-status-icon-mix), var(--color-toast-status-text))",
                    },
                    "&.photosphere-toast-success .MuiButton-root": {
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset 0 0 0 1px var(--color-toast-status-text)",
                    },
                    "&.photosphere-toast-warning": {
                        backgroundColor: "color-mix(in srgb, var(--color-toast-warning) var(--toast-status-tint), var(--color-toast-bg))",
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset var(--toast-status-bar-width) 0 0 var(--color-toast-warning), var(--shadow-overlay)",
                    },
                    "&.photosphere-toast-warning .photosphere-toast-icon": {
                        color: "color-mix(in srgb, var(--color-toast-warning) var(--toast-status-icon-mix), var(--color-toast-status-text))",
                    },
                    "&.photosphere-toast-warning .MuiButton-root": {
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset 0 0 0 1px var(--color-toast-status-text)",
                    },
                    "&.photosphere-toast-error": {
                        backgroundColor: "color-mix(in srgb, var(--color-toast-danger) var(--toast-status-tint), var(--color-toast-bg))",
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset var(--toast-status-bar-width) 0 0 var(--color-toast-danger), var(--shadow-overlay)",
                    },
                    "&.photosphere-toast-error .photosphere-toast-icon": {
                        color: "color-mix(in srgb, var(--color-toast-danger) var(--toast-status-icon-mix), var(--color-toast-status-text))",
                    },
                    "&.photosphere-toast-error .MuiButton-root": {
                        color: "var(--color-toast-status-text)",
                        boxShadow: "inset 0 0 0 1px var(--color-toast-status-text)",
                    },
                },
                action: {
                    marginRight: 0,
                    gap: "var(--space-2)",
                    "& .MuiButton-root": {
                        color: "var(--color-toast-action)",
                        boxShadow: "inset 0 0 0 1px var(--color-toast-action)",
                    },
                },
            },
        },
        MuiSlider: {
            //
            // A slider takes its track, its fill and its knob from the slider tokens, on the
            // progress track colour.
            //
            styleOverrides: {
                root: {
                    height: "var(--slider-track-height)",
                    padding: "var(--space-3) 0",
                },
                rail: {
                    backgroundColor: "var(--color-progress-track)",
                    opacity: 1,
                },
                track: {
                    background: "var(--slider-fill)",
                    border: "none",
                },
                thumb: {
                    width: "var(--slider-thumb-size)",
                    height: "var(--slider-thumb-size)",
                    backgroundColor: "var(--color-panel)",
                    border: "2px solid var(--color-accent)",
                    boxShadow: "var(--shadow-raised)",
                    "&:hover, &.Mui-focusVisible": {
                        boxShadow: "0 0 0 var(--space-1) var(--color-hover)",
                    },
                    "&.Mui-focusVisible": FOCUS_RING,
                },
            },
        },
        MuiBadge: {
            styleOverrides: {
                badge: {
                    backgroundColor: "var(--color-badge-bg)",
                    color: "var(--color-badge-text)",
                    fontFamily: "var(--font-sans)",
                    fontSize: "var(--text-xs)",
                    fontWeight: "var(--weight-bold)",
                    minWidth: "calc(var(--space-4) + var(--space-1))",
                    height: "calc(var(--space-4) + var(--space-1))",
                    padding: "0 var(--space-1)",
                    borderRadius: "var(--radius-full)",
                },
                dot: {
                    minWidth: "var(--space-2)",
                    height: "var(--space-2)",
                    padding: 0,
                },
            },
        },
    },
});
