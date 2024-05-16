//
// The addition of the sequence number to the timestamp is a simple way to ensure that timestamps are unique.
//
let sequenceNo = 999;

//
// Creates a timestamp that is counting down to the year 3000.
//
export function createReverseChronoTimestamp(currentDate: Date): string {
    // Set the target date to the year 3000.
    const targetDate = new Date("3000-01-01T00:00:00Z");

    // Calculate the difference in milliseconds
    const diff = targetDate.getTime() - currentDate.getTime();
    const timestamp = diff.toString().padStart(20, '0') + '-' + sequenceNo.toString().padStart(3, '0');
    sequenceNo -= 1;
    if (sequenceNo <= 0) {
        sequenceNo = 999; // Reset.
    }
    return timestamp;
}