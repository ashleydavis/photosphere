export interface ITimestampProvider {
    now(): number;
    date(): Date;
}

export class TimestampProvider implements ITimestampProvider {
    now(): number {
        return Date.now();
    }

    date(): Date {
        return new Date();
    }
}