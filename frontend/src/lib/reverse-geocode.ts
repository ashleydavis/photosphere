import axios from "axios";

//
// https://developers.google.com/maps/documentation/javascript
// 
// Setup up project: https://developers.google.com/maps/documentation/javascript/cloud-setup
// Using API keys: https://developers.google.com/maps/documentation/javascript/get-api-key
// Reverse geocoding: https://developers.google.com/maps/documentation/javascript/examples/geocoding-reverse
// Had to wait 10 mins for the API key to come online: https://stackoverflow.com/a/27463276/25868
// I had to enable Maps, Places and Geocoding APIs to get the key to work.
//
// https://github.com/zhso/reverse-geocoding/blob/6ab209acd2c4d32438c947ecbd5bf4d50f4c5b8d/src/index.js#L18
//

const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY;

//
// Represents a GPS location.
//
export interface ILocation {
    lat: number;
    lng: number;
}

//
// A component of a GPS coordinate can be defined by a fraction.
//
type GPSCoordinateFraction = { numerator: number, denominator: number  };

//
// The numbers that make up GPS coordinates come in two separate forms. 
//
type GPSCoordinateNumber
    = number                 // A regular number.
    | GPSCoordinateFraction; // A number composed of a fraction.

function convertNumber(value: GPSCoordinateNumber): number {
    const fraction = value as GPSCoordinateFraction;
    if (fraction.numerator !== undefined && fraction.denominator !== undefined) {
        return fraction.numerator / fraction.denominator; // Convert to a regular number.
    }
    else {
        return value as number; // It is just a regular number.
    }
}

//
// Converts degress, minutes, seconds to degrees.
//
function convertToDegrees([degrees, minutes, seconds]: GPSCoordinateNumber[]): number {
    var deg = convertNumber(degrees);
    var min = convertNumber(minutes);
    var sec = convertNumber(seconds);
    return deg + (min / 60) + (sec / 3600);
}

//
// Converts exif coordinates to a location.
//
// https://gis.stackexchange.com/a/273402
//
export function convertExifCoordinates(exif: any): ILocation {

    const coordinates = {
        lat: convertToDegrees(exif.GPSLatitude),
        lng: convertToDegrees(exif.GPSLongitude),
    };

    if (exif.GPSLatitudeRef === "S") {
        // If the latitude reference is "S", the latitude is negative
        coordinates.lat = coordinates.lat * -1;
    }

    if (exif.GPSLongitudeRef === "W") {
        // If the longitude reference is "W", the longitude is negative (thanks ChatGPT!)
        coordinates.lng = coordinates.lng * -1;
    }

    return coordinates;
}

//
// Checks if the passed in coordinate is valid number.
//
function checkCoordinateOk(coordinate: any, msg: string) {
    if (coordinate === null || coordinate === undefined || Number.isNaN(coordinate) || !Number.isFinite(coordinate)) {
        throw new Error(msg);
    }
}

//
// Reverse geocode the requested location (needs lat and lng fields).
//
// You must set an approriately configured Google API key in the environment variable GOOGLE_API_KEY for this to work.
//
export async function reverseGeocode(location: ILocation): Promise<string | undefined> {

    if (location === null || location === undefined) {
        throw new Error(`Invalid location ${location}`);
    }

    checkCoordinateOk(location.lat, `Bad "lat" field of location: ${location.lat}`);
    checkCoordinateOk(location.lng, `Bad "lng" field of location: ${location.lng}`);

    if (!GOOGLE_API_KEY) {
        return undefined;
    }

    //
    // Uncomment this code to fake an error in the reverse geocoder.
    //
    // throw new Error("Reverse geocoding - fake error.");

    const url = `https://maps.googleapis.com/maps/api/geocode/json?latlng=${location.lat},${location.lng}&key=${GOOGLE_API_KEY}`
    const { data } = await axios.get(url);

    if (data.results && data.results.length > 0) {
        return data.results[0].formatted_address;
    }

    return undefined;
}
