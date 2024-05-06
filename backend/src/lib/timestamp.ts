
//
// Creates a timestamp that is counting down to the year 3000.
//
export function createReverseChronoTimestamp(currentDate: Date): string {
    // Set the target date to the year 3000.
    const targetDate = new Date("3000-01-01T00:00:00Z");

    // Calculate the difference in milliseconds
    const diff = targetDate.getTime() - currentDate.getTime();
    return diff.toString().padStart(20, '0');
}