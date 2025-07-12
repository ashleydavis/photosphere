import { ITimestampProvider } from 'utils';

export class TestTimestampProvider implements ITimestampProvider {
    private static readonly FIXED_TIMESTAMP = 1640995200000; // 2022-01-01T00:00:00.000Z
    private counter: number = 0;

    now(): number {
        return TestTimestampProvider.FIXED_TIMESTAMP + this.counter++;
    }

    date(): Date {
        return new Date(this.now());
    }

    reset(): void {
        this.counter = 0;
    }
}