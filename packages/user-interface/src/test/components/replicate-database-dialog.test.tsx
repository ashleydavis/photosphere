/**
 * @jest-environment jsdom
 */

import React from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { ReplicateDatabaseDialog } from "../../components/replicate-database-dialog";
import { JobsContext, type IJobsContext } from "../../context/jobs-context";
import { PlatformContextProvider, type IDatabaseEntry, type IPlatformContext } from "../../context/platform-context";
import { UuidGeneratorProvider } from "../../context/uuid-generator-context";

jest.mock("node-api/src/lib/replicate-database", () => ({
    replicateDatabase: jest.fn(),
}));

import { replicateDatabase } from "node-api/src/lib/replicate-database";

const mockReplicateDatabase = replicateDatabase as jest.MockedFunction<typeof replicateDatabase>;

//
// Builds a stub jobs context.
//
function stubJobs(): IJobsContext {
    return {
        jobs: [],
        registerJob: jest.fn(),
        updateJob: jest.fn(),
        completeJob: jest.fn(),
        cancelJob: jest.fn(),
    };
}

//
// Minimal source database entry for the dialog.
//
const sourceEntry: IDatabaseEntry = {
    name: "Source",
    description: "",
    path: "/source/db",
};

describe("ReplicateDatabaseDialog", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockReplicateDatabase.mockImplementation(() => new Promise(() => undefined));
    });

    test("running step exposes Run in background button and allows dismiss", async () => {
        const onClose = jest.fn();
        const jobs = stubJobs();
        const platform = {
            pickFolder: jest.fn(),
        } as unknown as IPlatformContext;

        render(
            <UuidGeneratorProvider value={{ generate: () => "uuid-1" }}>
                <PlatformContextProvider value={platform}>
                    <JobsContext.Provider value={jobs}>
                        <ReplicateDatabaseDialog
                            open={true}
                            sourceEntry={sourceEntry}
                            encryptionSecrets={[]}
                            s3Secrets={[]}
                            geocodingSecrets={[]}
                            onClose={onClose}
                        />
                    </JobsContext.Provider>
                </PlatformContextProvider>
            </UuidGeneratorProvider>
        );

        const destPathRoot = document.querySelector('[data-id="replicate-dest-path-input"]') as HTMLElement;
        const destPathInput = destPathRoot.querySelector("input") as HTMLInputElement;
        fireEvent.change(destPathInput, {
            target: { value: "/dest/db" },
        });

        await act(async () => {
            fireEvent.click(document.querySelector('[data-id="replicate-start-button"]') as Element);
        });

        await waitFor(() => {
            expect(document.querySelector('[data-id="replicate-run-in-background-button"]')).toBeTruthy();
        });

        expect(jobs.registerJob).toHaveBeenCalledWith(expect.objectContaining({
            id: "/source/db",
            sourceTag: "/source/db",
            name: "Replicating to /dest/db",
            cancellable: true,
        }));

        fireEvent.click(document.querySelector('[data-id="replicate-run-in-background-button"]') as Element);
        expect(onClose).toHaveBeenCalled();
        expect(screen.getByText("Run in background")).toBeTruthy();
    });
});
