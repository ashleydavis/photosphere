import React from "react";
import { StyledEngineProvider, ThemeProvider } from "@mui/material/styles";
import GlobalStyles from "@mui/material/GlobalStyles";
import { photosphereTheme } from "../lib/mui-theme";

//
// Props for PhotosphereThemeProvider.
//
interface IPhotosphereThemeProviderProps {
    //
    // The part of the app drawn in the theme.
    //
    children: React.ReactNode;
}

//
// Draws its children in the Photosphere MUI theme. MUI's styles go in the `mui` CSS layer, below
// Tailwind's utilities, so a Tailwind class on an MUI component wins.
//
export function PhotosphereThemeProvider({ children }: IPhotosphereThemeProviderProps) {
    return (
        <StyledEngineProvider enableCssLayer={true}>
            <GlobalStyles styles="@layer theme, base, mui, components, utilities;" />
            <ThemeProvider theme={photosphereTheme} defaultMode="system">
                {children}
            </ThemeProvider>
        </StyledEngineProvider>
    );
}
