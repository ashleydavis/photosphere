import { beforeEach, describe, expect, mock, test } from "bun:test";

const infoMock = mock((message: string) => {});

mock.module("utils", () => ({
    log: {
        info: infoMock,
        error: () => {},
        warn: () => {},
        event: () => {},
        exception: () => {},
    },
}));

import { logSyncGate } from "../lib/sync-gate-log";

describe("logSyncGate", () => {
    beforeEach(() => {
        infoMock.mockClear();
    });

    test("logs Sync gate set to true", () => {
        logSyncGate(true);
        expect(infoMock).toHaveBeenCalledTimes(1);
        expect(infoMock).toHaveBeenCalledWith("Sync gate set to true");
    });

    test("logs Sync gate set to false", () => {
        logSyncGate(false);
        expect(infoMock).toHaveBeenCalledTimes(1);
        expect(infoMock).toHaveBeenCalledWith("Sync gate set to false");
    });
});
