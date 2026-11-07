import { toJsonValue } from '../lib/to-json-value';

describe('toJsonValue', () => {
    test('gives a value built from an interface as JSON, leaving out undefined fields', () => {
        interface IEntry {
            name: string;
            origin?: string;
        }
        const entry: IEntry = { name: 'photos', origin: undefined };

        expect(toJsonValue(entry)).toEqual({ name: 'photos' });
    });

    test('keeps nested lists and nulls', () => {
        expect(toJsonValue({ items: [1, 'two', null] })).toEqual({ items: [1, 'two', null] });
    });

    test('throws for a value that has no JSON form', () => {
        expect(() => toJsonValue(undefined)).toThrow('no JSON form');
    });
});
