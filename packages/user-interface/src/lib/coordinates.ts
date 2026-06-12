//
// A geographic position in decimal degrees.
//
export interface ICoordinates {
    //
    // Latitude in decimal degrees. Positive is north, negative is south.
    //
    lat: number;

    //
    // Longitude in decimal degrees. Positive is east, negative is west.
    //
    lng: number;
}

//
// Formats a single decimal-degree value as degrees and decimal minutes with a hemisphere letter,
// e.g. 32.30642 -> "32° 18.385' N".
//
export function formatDegreesMinutes(value: number, positiveHemisphere: string, negativeHemisphere: string): string {
    const hemisphere = value >= 0 ? positiveHemisphere : negativeHemisphere;
    const absolute = Math.abs(value);
    let degrees = Math.floor(absolute);
    let minutes = (absolute - degrees) * 60;

    // Guard against floating point rounding pushing the minutes display to 60.000.
    if (Number(minutes.toFixed(3)) >= 60) {
        minutes = 0;
        degrees += 1;
    }

    return `${degrees}° ${minutes.toFixed(3)}' ${hemisphere}`;
}

//
// Formats coordinates in the common degrees and decimal minutes format with hemisphere letters,
// e.g. "32° 18.385' N 122° 36.875' W".
//
export function formatCoordinates(coordinates: ICoordinates): string {
    const latText = formatDegreesMinutes(coordinates.lat, "N", "S");
    const lngText = formatDegreesMinutes(coordinates.lng, "E", "W");
    return `${latText} ${lngText}`;
}
