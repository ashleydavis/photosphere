//
// Do a binary search for an element in an array of strings sorted alphabetically (or timestamps in reverse chronological order).
// Returns the index of the target string in the array if it exists, otherwise returns -1.
//
export function binarySearch(arr: string[], target: string): number | undefined {
    // Early exit if the target is less than the first value or greater than the last value
    if (target < arr[0] || target > arr[arr.length - 1]) {
        return undefined;
    }

    let left = 0;
    let right = arr.length - 1;

    while (left <= right) {
        let mid = Math.floor((left + right) / 2);

        // Check if target is present at mid
        if (arr[mid] === target) {
            return mid;
        }

        // If target comes after mid, ignore left half
        if (arr[mid] < target) {
            left = mid + 1;
        }
        // If target comes before mid, ignore right half
        else {
            right = mid - 1;
        }
    }

    // If we reach here, then the element was not present
    return undefined;
}