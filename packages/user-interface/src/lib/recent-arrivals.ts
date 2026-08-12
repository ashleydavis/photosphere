//
// Which photos have just arrived on their own, so the gallery can show them landing.
//
// A photo the user imported is something they are already watching happen. One that automatic
// import brought in arrives with no warning, and without something to catch the eye it is
// indistinguishable from a gallery that has not changed. This records the arrivals for as long as
// the animation lasts and then forgets them, so scrolling back to an old photo later does not
// animate it again.
//

//
// How long an arrival stays worth animating, in milliseconds. Long enough for the animation to run
// and for the item to be scrolled into view, short enough that it is over before the user acts.
//
export const RECENT_ARRIVAL_MS = 1500;

//
// The asset ids that have arrived recently, each with the time it arrived.
//
const arrivalTimes = new Map<string, number>();

//
// Records that a photo has just arrived on its own.
//
export function markRecentArrival(assetId: string, nowMs: number): void {
    arrivalTimes.set(assetId, nowMs);
}

//
// Whether a photo arrived recently enough to be worth animating.
//
// Expiry is decided by comparing times rather than by a timer, so nothing has to be cancelled when
// the gallery is torn down and no timer can fire against a component that has gone.
//
export function isRecentArrival(assetId: string, nowMs: number): boolean {
    const arrivedAtMs = arrivalTimes.get(assetId);
    if (arrivedAtMs === undefined) {
        return false;
    }

    if (nowMs - arrivedAtMs > RECENT_ARRIVAL_MS) {
        arrivalTimes.delete(assetId);
        return false;
    }

    return true;
}

//
// Forgets every recorded arrival. For tests, and for switching databases, where the ids of one
// database mean nothing in another.
//
export function clearRecentArrivals(): void {
    arrivalTimes.clear();
}
