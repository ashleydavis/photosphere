import { binarySearch } from "../../lib/binary-search";

describe('binary search', () => {
    test('should return the index of the target string in the array if it exists', () => {
        const sortedStringArray = ["apple", "banana", "cherry", "grape", "orange", "strawberry", "watermelon"];
        expect(binarySearch(sortedStringArray, "orange")).toBe(4);
    });

    test('should return -1 if the target string does not exist in the array', () => {
        const sortedStringArray = ["apple", "banana", "cherry", "grape", "orange", "strawberry", "watermelon"];
        expect(binarySearch(sortedStringArray, "kiwi")).toBeUndefined();
    });

    test('should return -1 if the array is empty', () => {
        const sortedStringArray: string[] = [];
        expect(binarySearch(sortedStringArray, "orange")).toBeUndefined();
    });

    test('should return -1 if the target string is smaller than all strings in the array', () => {
        const sortedStringArray = ["apple", "banana", "cherry", "grape", "orange", "strawberry", "watermelon"];
        expect(binarySearch(sortedStringArray, "apricot")).toBeUndefined();
    });

    test('should return -1 if the target string is greater than all strings in the array', () => {
        const sortedStringArray = ["apple", "banana", "cherry", "grape", "orange", "strawberry", "watermelon"];
        expect(binarySearch(sortedStringArray, "zebra")).toBeUndefined();
    });

    test('should return the correct index when the array has only one element', () => {
        const sortedStringArray = ["orange"];
        expect(binarySearch(sortedStringArray, "orange")).toBe(0);
    });
});