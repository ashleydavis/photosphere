export interface IRandomGenerator {
    random(): number;
    randomInt(min: number, max: number): number;
    randomString(length: number): string;
}

export class RandomGenerator implements IRandomGenerator {
    random(): number {
        return Math.random();
    }

    randomInt(min: number, max: number): number {
        return Math.floor(Math.random() * (max - min + 1)) + min;
    }

    randomString(length: number): string {
        return Math.random().toString(36).substring(2, 2 + length);
    }
}