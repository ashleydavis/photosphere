export interface ITimestampProvider {
    now(): number;
    dateNow(): Date;
}

export class TimestampProvider implements ITimestampProvider {
    now(): number {
        return Date.now();
    }

    dateNow(): Date {
        return new Date();
    }
}