import { IRandomGenerator } from 'utils';

export class TestRandomGenerator implements IRandomGenerator {
    private seed: number = 12345;
    private counter: number = 0;

    random(): number {
        // Linear congruential generator for deterministic random numbers
        this.seed = (this.seed * 1103515245 + 12345) % 2147483647;
        return this.seed / 2147483647;
    }

    randomInt(min: number, max: number): number {
        return Math.floor(this.random() * (max - min + 1)) + min;
    }

    randomString(length: number): string {
        this.counter++;
        return `test-random-${this.counter}-${length}`;
    }

    reset(): void {
        this.seed = 12345;
        this.counter = 0;
    }
}