import type { ITimestampProvider } from './timestamp-provider';

//
// Mock timestamp provider for testing - allows manual control of timestamps
//
export class MockTimestampProvider implements ITimestampProvider {
    private currentTimestamp: number = 1000;

    constructor(initialTimestamp: number = 1000) {
        this.currentTimestamp = initialTimestamp;
    }

    //
    // Gets the current timestamp
    //
    now(): number {
        return this.currentTimestamp;
    }

    //
    // Gets a Date object with the current timestamp
    //
    dateNow(): Date {
        return new Date(this.currentTimestamp);
    }

    //
    // Sets the current timestamp (for testing)
    //
    setTimestamp(timestamp: number): void {
        this.currentTimestamp = timestamp;
    }

    //
    // Advances the timestamp by the specified milliseconds (for testing)
    //
    advance(ms: number): void {
        this.currentTimestamp += ms;
    }
}
