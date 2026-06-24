import React from "react";
import { render, screen } from "@testing-library/react";
import { App } from "../app";

// Verifies the Phase 1 "Hello world" placeholder renders. Automated stand-in
// for "see Hello world on device".
describe("App", () => {
    test("renders the Hello world placeholder", () => {
        render(<App />);
        expect(screen.getByText("Hello world")).toBeInTheDocument();
    });
});
